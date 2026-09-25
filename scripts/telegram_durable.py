"""Local, stdlib-only Telegram inbox, work lanes and effect/outbox journal.

The process lock is mandatory: startup converts interrupted RUNNING work to
UNCERTAIN, never replays a partly executed handler. QUEUED work is safe to claim.
No external operation is inside a SQLite transaction. This is at-most-once
automatic dispatch with visible uncertainty, not an exactly-once delivery claim.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import threading
import time


class ServiceAlreadyRunning(RuntimeError):
    pass


class ReconcileRequired(RuntimeError):
    pass


class EffectBlocked(RuntimeError):
    pass


def encode(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(encode(value).encode("utf-8")).hexdigest()


def _id(value):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        return None
    value = str(value)
    return value if re.fullmatch(r"-?[1-9][0-9]*", value) else None


def identity(update):
    cb = update.get("callback_query")
    item = cb if isinstance(cb, dict) else update.get("message", {})
    if not isinstance(item, dict):
        return None, None
    msg = item.get("message", {}) if cb is not None else item
    if not isinstance(msg, dict):
        return None, None
    chat, sender = msg.get("chat", {}), item.get("from", {})
    if not isinstance(chat, dict) or not isinstance(sender, dict):
        return None, None
    if sender.get("is_bot") is True:
        return None, None
    return _id(chat.get("id")), _id(sender.get("id"))


def authorized(update, config):
    """Chat membership alone never authenticates a sender in a group.

    Private chats default to matching the sender to chatId. An explicit ownerUserId
    or nonempty allowedUserIds further restricts either kind of chat. Missing,
    malformed or empty configured lists cannot broaden access.
    """
    if not isinstance(update, dict) or not isinstance(config, dict):
        return False
    chat, sender = identity(update)
    expected = _id(config.get("chatId"))
    if chat is None or sender is None or chat != expected:
        return False
    configured = "ownerUserId" in config or "allowedUserIds" in config
    permitted = None
    if "ownerUserId" in config:
        owner = _id(config["ownerUserId"])
        if owner is None or owner.startswith("-"):
            return False
        permitted = {owner}
    if "allowedUserIds" in config:
        values = config["allowedUserIds"]
        if not isinstance(values, list) or not values:
            return False
        ids = {_id(value) for value in values}
        if None in ids or any(value.startswith("-") for value in ids):
            return False
        permitted = ids if permitted is None else permitted & ids
    if configured and sender not in permitted:
        return False
    return configured if chat.startswith("-") else sender == chat


def lane_for(update):
    cb = update.get("callback_query")
    if isinstance(cb, dict):
        data = cb.get("data", "")
        if data == "cb_pause" or str(data).startswith("cb_proj_pause_"):
            return "pause"
        if data in {"cb_status", "cb_refresh", "cb_projects_list"} or str(data).startswith(("cb_proj_card_", "cb_proj_refresh_")):
            return "status"
        return "normal"
    raw = update.get("message", {}).get("text", "")
    raw = re.sub(r"^[^\w/]+", "", str(raw)).strip().lower()
    first = raw.split(maxsplit=1)[0].split("@", 1)[0] if raw else ""
    if first in {"/pause", "/mitm", "пауза", "/pause_h10", "/pause_vitalis", "пауза_h10", "пауза_vitalis"} or raw in {"полная пауза", "полная пауза (mitm)"}:
        return "pause"
    if first in {"/status", "/dash", "статус", "дэш", "дашборд"}:
        return "status"
    return "normal"


class ProcessLock:
    def __init__(self, path):
        self.file = open(path, "a+b")
        if self.file.tell() == 0:
            self.file.write(b"0")
            self.file.flush()
        self.file.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.file.close()
            raise ServiceAlreadyRunning("TELEGRAM_QUEUE_ALREADY_OWNED") from error

    def close(self):
        if not self.file.closed:
            if os.name == "nt":
                import msvcrt
                self.file.seek(0)
                msvcrt.locking(self.file.fileno(), msvcrt.LK_UNLCK, 1)
            self.file.close()


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript('''
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS updates(update_id INTEGER PRIMARY KEY,payload_hash TEXT NOT NULL,status TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS jobs(update_id INTEGER PRIMARY KEY,lane TEXT NOT NULL,payload TEXT NOT NULL,context TEXT NOT NULL,status TEXT NOT NULL,error_code TEXT);
            CREATE TABLE IF NOT EXISTS effects(operation_id TEXT PRIMARY KEY,update_id INTEGER NOT NULL,name TEXT NOT NULL,payload_hash TEXT NOT NULL,status TEXT NOT NULL,result TEXT,error_code TEXT);
            CREATE TABLE IF NOT EXISTS outbox(operation_id TEXT PRIMARY KEY,update_id INTEGER NOT NULL,lane TEXT NOT NULL,method TEXT NOT NULL,payload TEXT NOT NULL,status TEXT NOT NULL,error_code TEXT);
            CREATE TABLE IF NOT EXISTS reconciliations(id INTEGER PRIMARY KEY,operation_id TEXT NOT NULL,observed_performed INTEGER NOT NULL,evidence_ref TEXT NOT NULL,at REAL NOT NULL);
            ''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=NORMAL")
        db.execute("PRAGMA busy_timeout=15000")
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def recover_interrupted(self):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            for table in ("jobs", "effects", "outbox"):
                db.execute(f"UPDATE {table} SET status='UNCERTAIN',error_code='PROCESS_INTERRUPTED' WHERE status='RUNNING'")

    @property
    def offset(self):
        with self.connect() as db:
            row = db.execute("SELECT value FROM meta WHERE key='offset'").fetchone()
            return int(row[0]) if row else 0

    def submit(self, update, allowed, context):
        update_id = update.get("update_id")
        if type(update_id) is not int or update_id < 0:
            raise ValueError("INVALID_UPDATE_ID")
        payload_hash = digest(update)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT payload_hash FROM updates WHERE update_id=?", (update_id,)).fetchone()
            if old:
                return "DUPLICATE" if old[0] == payload_hash else "CONFLICT"
            state = "QUEUED" if allowed else "REJECTED"
            db.execute("INSERT INTO updates VALUES(?,?,?)", (update_id, payload_hash, state))
            if allowed:
                db.execute("INSERT INTO jobs VALUES(?,?,?,?,?,NULL)", (update_id, lane_for(update), encode(update), encode(context), "QUEUED"))
                cb = update.get("callback_query")
                if isinstance(cb, dict) and isinstance(cb.get("id"), str) and cb["id"]:
                    db.execute("INSERT INTO outbox VALUES(?,?,?,?,?,'QUEUED',NULL)",
                               (f"telegram:{update_id}:ack", update_id, "ack", "answerCallbackQuery", encode({"callback_query_id": cb["id"], "text": "Принято"})))
            previous = db.execute("SELECT value FROM meta WHERE key='offset'").fetchone()
            offset = max(int(previous[0]) if previous else 0, update_id + 1)
            db.execute("INSERT OR REPLACE INTO meta VALUES('offset',?)", (str(offset),))
            return state

    def claim(self, table, lane):
        if table not in {"jobs", "outbox"}:
            raise ValueError("table")
        key = "update_id" if table == "jobs" else "operation_id"
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(f"SELECT * FROM {table} WHERE lane=? AND status='QUEUED' ORDER BY rowid LIMIT 1", (lane,)).fetchone()
            if row:
                db.execute(f"UPDATE {table} SET status='RUNNING' WHERE {key}=?", (row[key],))
                return dict(row)

    def finish(self, table, key, status, error_code=None):
        if table not in {"jobs", "outbox", "effects"}:
            raise ValueError("table")
        column = "update_id" if table == "jobs" else "operation_id"
        with self.connect() as db:
            db.execute(f"UPDATE {table} SET status=?,error_code=? WHERE {column}=? AND status='RUNNING'", (status, error_code, key))

    def job(self, update_id):
        with self.connect() as db:
            row = db.execute("SELECT * FROM jobs WHERE update_id=?", (update_id,)).fetchone()
            return dict(row) if row else None

    def effect_rows(self, update_id):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM effects WHERE update_id=? ORDER BY rowid", (update_id,))]

    def diagnostics(self):
        with self.connect() as db:
            return {table: {row[0]: row[1] for row in db.execute(f"SELECT status,COUNT(*) FROM {table} GROUP BY status")} for table in ("jobs", "effects", "outbox")}

    def reconcile(self, operation_id, *, observed_performed, evidence_ref):
        """Offline authenticated operator seam: terminal resolution, never requeue.

        observed_performed=False permits a separately authorized fresh command;
        this method cannot silently repeat old owner intent.
        """
        if type(observed_performed) is not bool or not isinstance(evidence_ref, str) or not evidence_ref.strip():
            raise ValueError("RECONCILIATION_EVIDENCE_REQUIRED")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            changed = 0
            for table in ("effects", "outbox"):
                changed += db.execute(f"UPDATE {table} SET status=?,error_code=NULL WHERE operation_id=? AND status='UNCERTAIN'", ("RECONCILED_PERFORMED" if observed_performed else "RECONCILED_NOT_PERFORMED", operation_id)).rowcount
            if not changed:
                raise ReconcileRequired("NO_UNCERTAIN_OPERATION")
            db.execute("INSERT INTO reconciliations(operation_id,observed_performed,evidence_ref,at) VALUES(?,?,?,?)", (operation_id, observed_performed, evidence_ref, time.time()))


class Service:
    def __init__(self, database, config, handler, transport, *, context_provider=None):
        path = Path(database)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = ProcessLock(str(path) + ".lock")
        try:
            self.store = Store(path)
            self.store.recover_interrupted()
        except BaseException:
            self.lock.close()
            raise
        self.config, self.handler, self.transport = config, handler, transport
        self.context_provider = context_provider or (lambda: {})
        self.local = threading.local()
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.threads = []
        self.closed = False

    def current_config(self):
        return self.config() if callable(self.config) else self.config

    @property
    def context(self):
        return getattr(self.local, "context", None)

    @property
    def offset(self):
        return self.store.offset

    def submit(self, update):
        allowed = authorized(update, self.current_config())
        status = self.store.submit(update, allowed, self.context_provider() if allowed else {})
        self.wake.set()
        return status

    def start(self):
        if self.threads or self.closed:
            return
        for table, lanes in (("jobs", ("normal", "pause", "status")), ("outbox", ("ack", "notify"))):
            for lane in lanes:
                thread = threading.Thread(target=self._worker, args=(table, lane), name="telegram-" + lane, daemon=True)
                self.threads.append(thread)
                thread.start()

    def close(self):
        if self.closed:
            return
        self.stop.set()
        self.wake.set()
        for thread in self.threads:
            thread.join(timeout=2)
        if any(thread.is_alive() for thread in self.threads):
            # Releasing the process lock while external effects still execute
            # would permit a second owner. Keep the lock until process exit.
            raise RuntimeError("WORKER_STILL_ACTIVE; PROCESS_LOCK_RETAINED")
        self.lock.close()
        self.closed = True

    def _worker(self, table, lane):
        while not self.stop.is_set():
            try:
                row = self.store.claim(table, lane)
                if row:
                    self._run_job(row) if table == "jobs" else self._deliver(row)
                    continue
            except sqlite3.Error:
                # DB faults cannot authorize fallback direct execution.
                pass
            self.wake.wait(.05)
            self.wake.clear()

    def _run_job(self, row):
        update_id = row["update_id"]
        update = json.loads(row["payload"])
        if not authorized(update, self.current_config()):
            self.store.finish("jobs", update_id, "REJECTED", "AUTH_REVOKED")
            return
        self.local.context = {"update_id": update_id, "update": update, "lane": row["lane"], "sequence": 0, "binding": json.loads(row["context"])}
        try:
            self.handler(update)
        except EffectBlocked:
            self.store.finish("jobs", update_id, "BLOCKED", "EFFECT_FENCED")
            self._problem_notice("BLOCKED", "Команда не выполнена: состояние или разрешение изменилось. Проверьте /status.")
        except BaseException:
            self.store.finish("jobs", update_id, "UNCERTAIN", "HANDLER_RESULT_UNCERTAIN")
            self._problem_notice("UNCERTAIN", "Результат команды неизвестен. Автоматического повтора нет; нужна проверка получателя. См. /status.")
        else:
            self.store.finish("jobs", update_id, "DONE")
        finally:
            self.local.context = None

    def _deliver(self, row):
        try:
            job = self.store.job(row["update_id"])
            if not job or not authorized(json.loads(job["payload"]), self.current_config()):
                self.store.finish("outbox", row["operation_id"], "REJECTED", "AUTH_REVOKED")
                return
            result = self.transport(row["method"], json.loads(row["payload"]))
            if isinstance(result, dict) and result.get("ok") is True:
                self.store.finish("outbox", row["operation_id"], "DONE")
            else:
                self.store.finish("outbox", row["operation_id"], "UNCERTAIN", "DELIVERY_NOT_VERIFIED")
        except BaseException:
            self.store.finish("outbox", row["operation_id"], "UNCERTAIN", "DELIVERY_RESULT_UNCERTAIN")

    def _problem_notice(self, code, text):
        try:
            chat, _ = identity(self.context["update"])
            self.notify("sendMessage", {"chat_id": chat, "text": f"{code} · update {self.context['update_id']}: {text}"})
        except Exception:
            pass  # The local job remains visible even if its notice cannot queue.

    def _operation(self, name):
        context = self.context
        if context is None:
            raise EffectBlocked("DURABLE_AUTHENTICATED_JOB_REQUIRED")
        context["sequence"] += 1
        return f"telegram:{context['update_id']}:{context['sequence']}:{name}"

    def notify(self, method, payload):
        operation_id = self._operation(method)
        with self.store.connect() as db:
            db.execute("INSERT INTO outbox VALUES(?,?,?,?,?,'QUEUED',NULL)", (operation_id, self.context["update_id"], "notify", method, encode(payload)))
        self.wake.set()
        return {"ok": True, "queued": True, "delivery_verified": False}

    def effect(self, name, arguments, effect, *, gate=None):
        operation_id = self._operation(name)
        with self.store.connect() as db:
            db.execute("INSERT INTO effects VALUES(?,?,?,?, 'RUNNING',NULL,NULL)", (operation_id, self.context["update_id"], name, digest(arguments)))
        try:
            if gate:
                result = gate(operation_id, effect)
            else:
                result = effect()
            # A zero process exit or Telegram ok is delivery evidence only. Failed
            # legacy return dictionaries do not prove absence of an external effect.
            if isinstance(result, dict) and (result.get("ok") is False or result.get("success") is False):
                raise ReconcileRequired("EFFECT_RESULT_UNCERTAIN")
        except EffectBlocked:
            self.store.finish("effects", operation_id, "BLOCKED", "EFFECT_FENCED")
            raise
        except BaseException:
            self.store.finish("effects", operation_id, "UNCERTAIN", "EFFECT_RESULT_UNCERTAIN")
            raise
        self.store.finish("effects", operation_id, "DONE")
        return result
