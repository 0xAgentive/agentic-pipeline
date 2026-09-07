"""Transactional pause/recovery state, Python stdlib only.

No process control, messaging, browser control, credential reads or network calls.
This module does NOT authenticate callers. Adapters must authenticate owner commands
before owner_resume/reconcile. Epochs and tokens prevent stale work, not hostile code
with filesystem access. All mutations use one local SQLite database; legacy JSON is
an import/export view and must cease being a writable source at migration cutover.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import secrets
import sqlite3
import time

MANUAL = frozenset({"MANUAL", "USER_PAUSE", "MAN_IN_THE_MIDDLE", "PRE_SLEEP", "PRE_HIBERNATE"})
RETRYABLE = frozenset({"TRANSIENT_NETWORK", "TRANSIENT_SERVER", "TRANSIENT_RATE_LIMIT"})
NON_RETRYABLE = frozenset({"QUOTA_EXHAUSTED", "AUTH", "SCHEMA", "POLICY", "UNKNOWN", "OWNER_DECISION_REQUIRED"})
MODES = MANUAL | RETRYABLE | NON_RETRYABLE | {"NORMAL"}


class Rejected(RuntimeError):
    """Stable reason code. Adapters must surface HOLD, never interpret as permission."""


def validate_state(state, *, legacy=False):
    """Shared fail-closed validation, including every nested project pause."""
    if not isinstance(state, dict) or type(state.get("is_standby")) is not bool or state.get("mode") not in MODES:
        raise Rejected("INVALID_STATE")
    if not legacy and (type(state.get("schema_version")) is not int or state["schema_version"] != 1 or
                       type(state.get("epoch")) is not int or state["epoch"] < 0 or
                       type(state.get("revision")) is not int or state["revision"] < 0):
        raise Rejected("INVALID_STATE")
    projects = state.get("projects", {}) if legacy else state.get("projects")
    if not isinstance(projects, dict):
        raise Rejected("INVALID_STATE")
    for project, value in projects.items():
        if not isinstance(project, str) or not project or not isinstance(value, dict) or type(value.get("is_paused")) is not bool:
            raise Rejected("INVALID_STATE")
        if "mode" in value and value["mode"] not in MODES:
            raise Rejected("INVALID_STATE")
        if value["is_paused"] and value.get("mode") == "NORMAL":
            raise Rejected("INVALID_STATE")
    if state["is_standby"] and state["mode"] == "NORMAL":
        raise Rejected("INVALID_STATE")
    return state


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(name)
    return value


def _now(value):
    value = time.time() if value is None else _number(value, "now")
    if value < 0:
        raise ValueError("now")
    return value


def _iso(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat()


def _identifier(value, name):
    if not isinstance(value, str) or not value or len(value) > 256 or any(ord(c) < 32 for c in value):
        raise ValueError(name)
    return value


def classify_failure(http_status=None, *, code="", retry_after=None):
    """Use structured error fields only. Free-form model/transcript prose is UNKNOWN."""
    if code in {"insufficient_quota", "quota_exhausted", "credits_exhausted"}:
        return "QUOTA_EXHAUSTED"
    if code in {"unauthenticated", "invalid_api_key", "permission_denied"} or http_status in (401, 403):
        return "AUTH"
    if code in {"invalid_argument", "invalid_schema", "validation_error"}:
        return "SCHEMA"
    if code in {"policy_violation", "policy_denied"}:
        return "POLICY"
    if code in {"rate_limit_exceeded", "temporary_rate_limit"} and http_status == 429 and retry_after is not None:
        return "TRANSIENT_RATE_LIMIT" if _number(retry_after, "retry_after") >= 0 else "UNKNOWN"
    if http_status in (500, 502, 503, 504):
        return "TRANSIENT_SERVER"
    if code in {"stream_interrupted", "connection_reset", "timeout", "connection_refused"}:
        return "TRANSIENT_NETWORK"
    return "UNKNOWN"


def retry_delay(attempt, *, retry_after=None, random_fraction=None):
    """Full jitter with Retry-After as a lower bound; computes only, never sleeps."""
    if type(attempt) is not int or not 1 <= attempt <= 4:
        raise ValueError("attempt")
    fraction = secrets.randbelow(1_000_001) / 1_000_000 if random_fraction is None else _number(random_fraction, "random_fraction")
    if not 0 <= fraction <= 1:
        raise ValueError("random_fraction")
    server_delay = 0 if retry_after is None else _number(retry_after, "retry_after")
    if server_delay < 0:
        raise ValueError("retry_after")
    return max(server_delay, min(60, 2 ** attempt) * fraction)


class Coordinator:
    def __init__(self, database):
        self.database = Path(database)
        self.database.parent.mkdir(parents=True, exist_ok=True)
        # Filesystem must be a local disk; a network share is not a supported target.
        with self._connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL)")
            db.execute("""CREATE TABLE IF NOT EXISTS operations (
                project TEXT NOT NULL, operation TEXT NOT NULL, status TEXT NOT NULL,
                attempts INTEGER NOT NULL, max_attempts INTEGER NOT NULL,
                retry_at REAL NOT NULL, evidence_ref TEXT,
                PRIMARY KEY(project, operation))""")
            db.execute("CREATE TABLE IF NOT EXISTS lease (id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS budgets (project TEXT, budget_key TEXT, attempts INTEGER NOT NULL, PRIMARY KEY(project,budget_key))")

    def _connect(self):
        db = sqlite3.connect(self.database, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA busy_timeout=5000")
        return db

    @contextmanager
    def _transaction(self):
        db = self._connect()
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _read(db):
        row = db.execute("SELECT data FROM state WHERE id=1").fetchone()
        if row is None:
            raise Rejected("NOT_INITIALIZED")
        state = json.loads(row["data"])
        return validate_state(state)

    @staticmethod
    def _save(db, state):
        db.execute("INSERT OR REPLACE INTO state(id,data) VALUES(1,?)", (json.dumps(state, ensure_ascii=False),))

    @staticmethod
    def _change(state, now):
        state["revision"] += 1
        state["epoch"] += 1
        state["updated_at_utc"] = _iso(now)

    def initialize(self, legacy):
        """Explicit cutover only; preserves legacy metadata, rejects ambiguous state."""
        validate_state(legacy, legacy=True)
        with self._transaction() as db:
            if db.execute("SELECT 1 FROM state").fetchone():
                return self._read(db)
            state = json.loads(json.dumps(legacy))
            state.update(schema_version=1, revision=0, epoch=0, runtime_instance=None)
            state.setdefault("projects", {})
            state.setdefault("last_pause_duration_sec", 0)
            self._save(db, state)
            return state

    def snapshot(self):
        with self._connect() as db:
            return self._read(db)

    def pause(self, mode, *, reason="", project=None, now=None, expected_epoch=None):
        """Pause unconditionally by default; an optional epoch is checked atomically."""
        if mode not in MODES - {"NORMAL"}:
            raise ValueError("mode")
        if project is not None:
            _identifier(project, "project")
        if not isinstance(reason, str) or len(reason) > 2048:
            raise ValueError("reason")
        now = _now(now)
        with self._transaction() as db:
            state = self._read(db)
            if expected_epoch is not None:
                if type(expected_epoch) is not int:
                    raise ValueError("pause epoch")
                if expected_epoch != state["epoch"]:
                    raise Rejected("STALE_EPOCH")
            target = state if project is None else state["projects"].setdefault(project, {"is_paused": False})
            flag = "is_standby" if project is None else "is_paused"
            if target.get(flag) and target.get("mode", "MANUAL") in MANUAL and mode not in MANUAL:
                return state
            if not target.get(flag):
                target["paused_at_utc"] = _iso(now)
            target.update({flag: True, "mode": mode, "reason": reason, "resumed_at_utc": None})
            self._change(state, now)
            self._save(db, state)
            return state

    def owner_resume(self, expected_epoch, *, project=None, all_projects=False, now=None):
        """Call only from an authenticated explicit owner action; does not send nudges."""
        if type(expected_epoch) is not int or type(all_projects) is not bool or (project is not None and all_projects):
            raise ValueError("resume arguments")
        now = _now(now)
        with self._transaction() as db:
            state = self._read(db)
            if expected_epoch != state["epoch"]:
                raise Rejected("STALE_EPOCH")
            if project is not None:
                _identifier(project, "project")
                targets = [(state["projects"].setdefault(project, {"is_paused": False}), "is_paused")]
            else:
                targets = [(state, "is_standby")]
                if all_projects:
                    targets.extend((value, "is_paused") for value in state["projects"].values())
            for target, flag in targets:
                if target.get(flag) and target.get("paused_at_utc"):
                    try:
                        started = datetime.fromisoformat(target["paused_at_utc"].replace("Z", "+00:00")).timestamp()
                        target["last_pause_duration_sec"] = max(0, int(now - started))
                    except (ValueError, TypeError):
                        target["last_pause_duration_sec"] = None
                target.update({flag: False, "mode": "NORMAL", "reason": "EXPLICIT_OWNER_RESUME", "resumed_at_utc": _iso(now)})
            self._change(state, now)
            self._save(db, state)
            return state

    def observe_runtime(self, instance, *, now=None):
        """Instance must include process creation time, not PID alone. Never resumes."""
        _identifier(instance, "runtime_instance")
        now = _now(now)
        with self._transaction() as db:
            state = self._read(db)
            if state["runtime_instance"] != instance:
                state["runtime_instance"] = instance
                self._change(state, now)
                self._save(db, state)
            return state

    def bind_work(self, project, work_item_id, goal_epoch, expected_epoch, *, now=None, contract=None):
        """Trusted work-admission hook; call only after actual work contract validation."""
        _identifier(project, "project")
        _identifier(work_item_id, "work_item_id")
        if not isinstance(goal_epoch, (str, int)) or isinstance(goal_epoch, bool) or goal_epoch == "":
            raise ValueError("goal_epoch")
        now = _now(now)
        with self._transaction() as db:
            state = self._read(db)
            if type(expected_epoch) is not int or expected_epoch != state["epoch"]:
                raise Rejected("STALE_EPOCH")
            if state["is_standby"] or state["projects"].get(project, {}).get("is_paused"):
                raise Rejected("PAUSED")
            binding = {"work_item_id": work_item_id, "goal_epoch": goal_epoch}
            if contract is not None:
                if not isinstance(contract, dict) or contract.get("owner_approved") is not True or contract.get("hard_stop") is not False:
                    raise Rejected("WORK_CONTRACT_INVALID")
                if contract.get("work_item_id") != work_item_id or type(contract.get("goal_epoch")) is not type(goal_epoch) or contract.get("goal_epoch") != goal_epoch:
                    raise Rejected("WORK_BINDING_MISMATCH")
                binding.update(contract)
            if state.get("work_bindings", {}).get(project) == binding:
                return state
            state.setdefault("work_bindings", {})[project] = binding
            # Admission changes this project binding; it is not a global pause/runtime fence.
            state["revision"] += 1
            state["updated_at_utc"] = _iso(now)
            self._save(db, state)
            return state

    @staticmethod
    def _allowed(state, project):
        for target, flag in [(state, "is_standby"), (state["projects"].get(project, {}), "is_paused")]:
            if target.get(flag):
                mode = target.get("mode", "MANUAL")
                if mode not in RETRYABLE:
                    raise Rejected("PAUSED:" + mode)

    def claim(self, owner, project, operation, failure_kind, *, now=None, lease_seconds=30, max_attempts=4, budget_key=None, expected_epoch=None):
        for value, name in [(owner, "owner"), (project, "project"), (operation, "operation")]:
            _identifier(value, name)
        if failure_kind not in RETRYABLE:
            raise Rejected("NON_RETRYABLE:" + str(failure_kind))
        if type(max_attempts) is not int or not 1 <= max_attempts <= 4:
            raise ValueError("max_attempts")
        if not 0 < _number(lease_seconds, "lease_seconds") <= 60:
            raise ValueError("lease_seconds")
        now = _now(now)
        if budget_key is not None:
            _identifier(budget_key, "budget_key")
        with self._transaction() as db:
            # Interlock legacy callers with the v2 shared final effect owner.
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='v2_effect_lease'").fetchone():
                v2 = db.execute("SELECT data FROM v2_effect_lease WHERE id=1").fetchone()
                if v2 and json.loads(v2["data"])["expires_at"] > now:
                    raise Rejected("EFFECT_OWNED")
                if db.execute("SELECT 1 FROM v2_effects WHERE json_extract(data,'$.status') IN ('DISPATCHED','UNCERTAIN')").fetchone():
                    raise Rejected("RECONCILIATION_REQUIRED")
            state = self._read(db)
            if expected_epoch is not None and (type(expected_epoch) is not int or expected_epoch != state["epoch"]):
                raise Rejected("STALE_EPOCH")
            self._allowed(state, project)
            prior = db.execute("SELECT data FROM lease WHERE id=1").fetchone()
            if prior:
                old = json.loads(prior["data"])
                if old["expires_at"] > now:
                    raise Rejected("RECOVERY_OWNED")
                old_op = db.execute("SELECT status FROM operations WHERE project=? AND operation=?", (old["project"], old["operation"])).fetchone()
                if old_op["status"] == "DISPATCHED":
                    raise Rejected("RECONCILIATION_REQUIRED")
                db.execute("DELETE FROM lease")
            row = db.execute("SELECT * FROM operations WHERE project=? AND operation=?", (project, operation)).fetchone()
            if row:
                if row["status"] == "SUCCEEDED":
                    raise Rejected("ALREADY_SUCCEEDED")
                if row["status"] in {"UNCERTAIN", "DISPATCHED"}:
                    raise Rejected("RECONCILIATION_REQUIRED")
                if row["attempts"] >= min(max_attempts, row["max_attempts"]):
                    raise Rejected("ATTEMPTS_EXHAUSTED")
                if row["retry_at"] > now:
                    raise Rejected("BACKOFF")
                attempts = row["attempts"] + 1
                max_attempts = min(max_attempts, row["max_attempts"])
            else:
                attempts = 1
            if budget_key is not None:
                budget = db.execute("SELECT attempts FROM budgets WHERE project=? AND budget_key=?", (project, budget_key)).fetchone()
                used = budget["attempts"] if budget else 0
                if used >= max_attempts:
                    raise Rejected("WORK_BUDGET_EXHAUSTED")
                db.execute("INSERT OR REPLACE INTO budgets VALUES(?,?,?)", (project, budget_key, used + 1))
            lease = dict(owner=owner, project=project, operation=operation, token=secrets.token_hex(24),
                         epoch=state["epoch"], expires_at=now + lease_seconds, attempt=attempts)
            db.execute("INSERT OR REPLACE INTO operations VALUES(?,?,?,?,?,?,?)", (project, operation, "RESERVED", attempts, max_attempts, 0, None))
            db.execute("INSERT OR REPLACE INTO lease VALUES(1,?)", (json.dumps(lease),))
            return lease

    @staticmethod
    def _check_lease(db, supplied, now):
        state = Coordinator._read(db)
        if supplied.get("epoch") != state["epoch"]:
            raise Rejected("STALE_EPOCH")
        row = db.execute("SELECT data FROM lease WHERE id=1").fetchone()
        if not row:
            raise Rejected("STALE_TOKEN")
        stored = json.loads(row["data"])
        if any(stored.get(key) != supplied.get(key) for key in stored):
            raise Rejected("STALE_TOKEN")
        if stored["expires_at"] <= now:
            raise Rejected("EXPIRED_LEASE")
        Coordinator._allowed(state, stored["project"])
        return stored

    def begin_dispatch(self, lease, *, now=None):
        """Final durable pre-effect gate. A crash after this requires reconciliation."""
        now = _now(now)
        with self._transaction() as db:
            stored = self._check_lease(db, lease, now)
            changed = db.execute("UPDATE operations SET status='DISPATCHED' WHERE project=? AND operation=? AND status='RESERVED'", (stored["project"], stored["operation"])).rowcount
            if changed != 1:
                raise Rejected("ALREADY_DISPATCHED")
            return dict(stored)

    def ack(self, lease, *, outcome, now=None, retry_after=None, random_fraction=None):
        """SUCCEEDED means transport receipt only; never changes pause or project status."""
        if outcome not in {"SUCCEEDED", "FAILED_SAFE", "UNCERTAIN"}:
            raise ValueError("outcome")
        now = _now(now)
        with self._transaction() as db:
            stored = self._check_lease(db, lease, now)
            retry_at = now + retry_delay(stored["attempt"], retry_after=retry_after, random_fraction=random_fraction) if outcome == "FAILED_SAFE" else 0
            changed = db.execute("UPDATE operations SET status=?,retry_at=? WHERE project=? AND operation=? AND status='DISPATCHED'", (outcome, retry_at, stored["project"], stored["operation"])).rowcount
            if changed != 1:
                raise Rejected("NOT_DISPATCHED")
            db.execute("DELETE FROM lease")

    def operation(self, project, operation):
        with self._connect() as db:
            row = db.execute("SELECT * FROM operations WHERE project=? AND operation=?", (project, operation)).fetchone()
            return dict(row) if row else None

    def reconcile(self, project, operation, expected_epoch, observed_performed, evidence_ref, *, now=None):
        """Owner/trusted receiver reconciliation after a side-effect uncertainty.

        Caller must verify the referenced evidence and bind it to the actual target
        turn. This method stores the reference; it does not authenticate that evidence.
        """
        if not isinstance(evidence_ref, str) or not evidence_ref.strip() or len(evidence_ref) > 1024:
            raise Rejected("EVIDENCE_REQUIRED")
        if type(observed_performed) is not bool:
            raise ValueError("observed_performed")
        now = _now(now)
        with self._transaction() as db:
            state = self._read(db)
            if expected_epoch != state["epoch"]:
                raise Rejected("STALE_EPOCH")
            row = db.execute("SELECT * FROM operations WHERE project=? AND operation=?", (project, operation)).fetchone()
            if not row or row["status"] not in {"DISPATCHED", "UNCERTAIN"}:
                raise Rejected("NOT_RECONCILABLE")
            db.execute("UPDATE operations SET status=?,evidence_ref=?,retry_at=? WHERE project=? AND operation=?", ("SUCCEEDED" if observed_performed else "FAILED_SAFE", evidence_ref, now, project, operation))
            active = db.execute("SELECT data FROM lease WHERE id=1").fetchone()
            if active:
                active = json.loads(active["data"])
                if active["project"] == project and active["operation"] == operation:
                    db.execute("DELETE FROM lease")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Read-only recovery state inspection")
    parser.add_argument("database", type=Path)
    args = parser.parse_args()
    if not args.database.is_file():
        parser.error("database does not exist; initialize from validated state at cutover")
    print(json.dumps(Coordinator(args.database).snapshot(), ensure_ascii=False, indent=2))
