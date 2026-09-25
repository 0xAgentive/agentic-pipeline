#!/usr/bin/env python3
"""
Agentic Pipeline — Telegram Remote Cycle Controller Daemon.
Provides complete remote control of the autonomous cyclic system via Telegram:
1. Dashboard & Status (/status, inline buttons)
2. Scalable Multi-Project Management (/projects, dynamic cards, isolated pause/resume)
3. Bidirectional Antigravity Orchestrator Channel (/orchestrator, /set_orchestrator, reactive wakeup)
4. Strategic Directive Injection (/directive <text>, /directive_clear)
5. Cyclic Service Restarts (/restart via supervisor)
6. PC Power Management (/sleep with confirmation)

Designed for 24/7 unattended operation with zero external pip dependencies.
"""
from runtime_paths import runtime_path

import os
from pipeline_runtime_state import snapshot as runtime_snapshot, owner_set as runtime_owner_set
import sys
import json
import time
import socket
import ctypes
import datetime as dt
import subprocess
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path
from typing import Optional, Dict, Any, List, Tuple

# Prevent indefinite socket hangs on Windows
socket.setdefaulttimeout(15.0)

# Ensure UTF-8 stdout/stderr
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Paths
STATE_ROOT = Path(runtime_path("AGENTIC_STATE_ROOT",""))
CONFIG_PATH = Path(runtime_path("ANTIGRAVITY_DATA_ROOT","companion_bridge_config.json"))
STANDBY_STATE_PATH = STATE_ROOT / "STANDBY_STATE.json"
OWNER_DIRECTIVE_PATH = STATE_ROOT / "OWNER_STRATEGIC_DIRECTIVE.json"
SUPERVISOR_PIDS_PATH = STATE_ROOT / "supervisor_pids.json"
SEEN_PACKETS_PATH = Path(runtime_path("ANTIGRAVITY_DATA_ROOT","companion_seen_packets.json"))
HEARTBEAT_PATH = STATE_ROOT / "TELEGRAM_BOT_HEARTBEAT.json"
LOG_DIR = STATE_ROOT / "logs"
BOT_LOG = LOG_DIR / "telegram_bot.log"

PROJECT_REGISTRY_PATH = Path(runtime_path("AGENTIC_PROJECT_REGISTRY",""))
ORCHESTRATOR_CONFIG_PATH = STATE_ROOT / "ORCHESTRATOR_CONFIG.json"
ORCHESTRATOR_CONFIG_AGY = Path(runtime_path("AGENTIC_PIPELINE_ROOT",".agy/ORCHESTRATOR_CONFIG.json"))
ORCHESTRATOR_INBOX_PATH = STATE_ROOT / "ORCHESTRATOR_INBOX.ndjson"
LANGUAGE_SERVER_EXE = Path(runtime_path("ANTIGRAVITY_INSTALL_ROOT","resources/bin/language_server.exe"))
ACTIVE_LS_ENV_PATH = STATE_ROOT / "ACTIVE_LS_ENV.json"
BRAIN_ROOT = Path(runtime_path("ANTIGRAVITY_DATA_ROOT","brain"))

SUPERVISOR_PY = Path(runtime_path("AGENTIC_RUNTIME_SCRIPTS_DIR","agentic_cyclic_supervisor.py"))
PYTHON_EXE = Path(runtime_path("AGENTIC_PYTHON",""))
PYTHONW_EXE = Path(runtime_path("AGENTIC_PYTHONW",""))
NODE_EXE = Path(runtime_path("AGENTIC_NODE",""))
COMPANION_BRIDGE_JS = Path(runtime_path("AGENTIC_RUNTIME_SCRIPTS_DIR","companion_bridge.js"))

PENDING_INPUT_PATH = STATE_ROOT / "PENDING_TELEGRAM_INPUT.json"
PENDING_REPLY_PATH = STATE_ROOT / "PENDING_TELEGRAM_REPLY.json"
CACHED_TEXT_PATH = STATE_ROOT / "CACHED_TELEGRAM_TEXT.json"

DEFAULT_ORCHESTRATOR_ID = "b181c7df-b538-4519-96c8-589605172fdb"
CREATE_NO_WINDOW = 0x08000000


def log_event(message: str) -> None:
    now_str = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    line = f"[{now_str}] {message}\n"
    try:
        print(line, end="", flush=True)
    except Exception:
        pass
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with BOT_LOG.open("a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def write_heartbeat() -> None:
    try:
        data = {
            "pid": os.getpid(),
            "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "epoch": time.time()
        }
        try:
            from process_identity import current_identity
            data["process_identity"] = current_identity()
        except Exception:
            data["process_identity"] = None
            data["identity_status"] = "UNKNOWN"
        tmp = HEARTBEAT_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data), encoding="utf-8")
        tmp.replace(HEARTBEAT_PATH)
    except Exception:
        pass


def load_config() -> dict:
    if CONFIG_PATH.is_file():
        try:
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def get_telegram_creds() -> tuple[str, str]:
    cfg = load_config().get("telegram", {})
    return str(cfg.get("botToken", "")), str(cfg.get("chatId", ""))


# Telegram API Helper
def api_request(method: str, payload: Optional[dict] = None, timeout: int = 30) -> dict:
    token, _ = get_telegram_creds()
    if not token:
        return {"ok": False, "error": "No botToken configured"}

    url = f"https://api.telegram.org/bot{token}/{method}"
    data = None
    headers = {"Connection": "close"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"

    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if payload else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        try:
            return json.loads(err_body)
        except Exception:
            return {"ok": False, "error": f"HTTP {e.code}: {err_body}"}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


def _bind_resume_buttons(markup):
    if not markup:
        return markup
    markup = json.loads(json.dumps(markup))
    epoch = get_standby_state().get("epoch")
    for row in markup.get("inline_keyboard", []):
        for button in row:
            data = button.get("callback_data", "")
            if data == "cb_resume" or data.startswith("cb_proj_resume_"):
                button["callback_data"] = data + ":e:" + str(epoch)
    return markup

def send_message(chat_id: str, text: str, reply_markup: Optional[dict] = None) -> dict:
    reply_markup = _bind_resume_buttons(reply_markup)
    payload: Dict[str, Any] = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return api_request("sendMessage", payload)


def edit_message(chat_id: str, message_id: int, text: str, reply_markup: Optional[dict] = None) -> dict:
    reply_markup = _bind_resume_buttons(reply_markup)
    payload: Dict[str, Any] = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    res = api_request("editMessageText", payload)
    if not res.get("ok") and "message is not modified" in str(res.get("description", "")):
        return {"ok": True, "result": "not_modified"}
    return res


def answer_callback(callback_query_id: str, text: str = "", show_alert: bool = False) -> dict:
    payload = {
        "callback_query_id": callback_query_id,
        "text": text,
        "show_alert": show_alert
    }
    return api_request("answerCallbackQuery", payload)


# =========================================================================
# Antigravity Orchestrator Integration (Dynamic Connection & Auto-Discovery)
# =========================================================================

_CACHED_LS_ENV: Optional[Dict[str, str]] = None
_CACHED_LS_ENV_TIME: float = 0.0
_LAST_DISCOVERED_ORCH_ID: Optional[str] = None


def get_active_antigravity_ls_env(force_refresh: bool = False) -> dict:
    """Use the same verified endpoint provider as the native guard."""
    global _CACHED_LS_ENV, _CACHED_LS_ENV_TIME
    from native_health import configured_connection
    try:
        resolved=configured_connection()
        _CACHED_LS_ENV=resolved
        _CACHED_LS_ENV_TIME=time.time()
        return resolved
    except Exception:
        _CACHED_LS_ENV=None
        _CACHED_LS_ENV_TIME=0.0
        log_event("[NATIVE_CONNECTION_HOLD] Verified native connection unavailable")
        return {}



def run_agentapi_command(args: list[str], timeout: int = 12) -> tuple[int, str, str]:
    """Runs agentapi with dynamic env; mutating send-message is single attempt."""
    from process_identity import identity_matches,observe_pid
    from native_health import same_path
    if not LANGUAGE_SERVER_EXE.is_file() or LANGUAGE_SERVER_EXE.is_symlink():
        return 1,"","NATIVE_EXECUTABLE_MISSING"
    exe = LANGUAGE_SERVER_EXE
    base_cmd = [str(exe), "agentapi"] + args

    # Mutating sends have no receiver-side idempotency proof: one attempt only.
    attempts = 1 if args and args[0] == 'send-message' else 2
    for attempt in range(attempts):
        force_refresh = (attempt > 0)
        ls_env = get_active_antigravity_ls_env(force_refresh=force_refresh)
        if not ls_env or not isinstance(ls_env.get("process_identity"),dict):
            return 1,"","NATIVE_CONNECTION_UNVERIFIED"
        identity=ls_env["process_identity"]
        try:
            if not same_path(identity["executable"],exe) or not identity_matches(identity,observe_pid(int(ls_env["ANTIGRAVITY_LS_PID"]))):
                return 1,"","NATIVE_PROCESS_CHANGED_BEFORE_COMMAND"
        except Exception:
            return 1,"","NATIVE_PROCESS_IDENTITY_UNVERIFIED"
        env = os.environ.copy()
        env.pop("ANTIGRAVITY_SOURCE_METADATA",None)
        if ls_env:
            for k in ["ANTIGRAVITY_LS_ADDRESS", "ANTIGRAVITY_CSRF_TOKEN", "ANTIGRAVITY_LS_PID"]:
                if k in ls_env:
                    env[k] = str(ls_env[k])

        try:
            res = subprocess.run(
                base_cmd,
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout,
                creationflags=CREATE_NO_WINDOW
            )
            if not identity_matches(identity,observe_pid(identity["pid"])):
                return 1,"","NATIVE_PROCESS_CHANGED_DURING_COMMAND"
            stdout = res.stdout.strip()
            stderr = res.stderr.strip()
            combined_err = f"{stderr} {stdout}".lower()

            is_conn_err = any(k in combined_err for k in [
                "unavailable", "dial tcp", "connectex", "connection refused",
                "actively refused", "antigravity_ls_address is not set"
            ])
            if is_conn_err and attempt == 0 and attempts > 1:
                log_event(f"AgentAPI connection error on attempt 1. Invalidating cache and retrying...")
                time.sleep(1.0)
                continue

            return res.returncode, stdout, stderr
        except subprocess.TimeoutExpired:
            return 124, "", "Тайм-аут ожидания ответа от language_server.exe"
        except Exception as ex:
            if attempt == 0 and attempts > 1:
                time.sleep(1.0)
                continue
            return 1, "", str(ex)

    return 1, "", "Не удалось подключиться к language_server.exe"


def find_latest_orchestrator_conversation() -> Optional[str]:
    """Auto-discovers the latest active session in brain directory matching the orchestrator workspaces."""
    if not BRAIN_ROOT.is_dir():
        return None
    try:
        candidates = []
        for d in BRAIN_ROOT.iterdir():
            if d.is_dir() and len(d.name) == 36 and "-" in d.name:
                t_file = d / ".system_generated" / "logs" / "transcript.jsonl"
                if t_file.is_file():
                    try:
                        candidates.append((d.name, t_file.stat().st_mtime))
                    except Exception:
                        pass
        if candidates:
            candidates.sort(key=lambda x: x[1], reverse=True)
            for cid, _ in candidates[:5]:
                val = validate_conversation_id(cid, check_discovery=False)
                if val.get("ok"):
                    ws_list = [str(w).lower() for w in val.get("workspaces", [])]
                    if any("agentic" in w or "pipeline" in w or "handoff" in w for w in ws_list):
                        return cid
    except Exception as e:
        log_event(f"Error finding latest orchestrator conversation: {e}")
    return None


def get_orchestrator_config() -> dict:
    for p in [ORCHESTRATOR_CONFIG_AGY, ORCHESTRATOR_CONFIG_PATH]:
        if p.is_file():
            try:
                return json.loads(p.read_text(encoding="utf-8"))
            except Exception:
                pass
    return {
        "conversation_id": DEFAULT_ORCHESTRATOR_ID,
        "title": "Agentic Pipeline Master Orchestrator",
        "workspaces": [
            runtime_path("AGENTIC_PIPELINE_ROOT",""),
            runtime_path("AGENTIC_ORCHESTRATOR_SEARCH_ROOT","")
        ],
        "updated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()
    }


def set_orchestrator_config(conv_id: str, title: str = "", workspaces: Optional[list] = None) -> dict:
    data = {
        "conversation_id": conv_id.strip(),
        "title": title or "Agentic Pipeline Master Orchestrator",
        "workspaces": workspaces or [],
        "updated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()
    }
    for p in [ORCHESTRATOR_CONFIG_AGY, ORCHESTRATOR_CONFIG_PATH]:
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
            tmp.replace(p)
        except Exception:
            pass
    return data


def validate_conversation_id(conv_id: str, check_discovery: bool = True) -> dict:
    global _LAST_DISCOVERED_ORCH_ID
    conv_id = conv_id.strip()
    if not conv_id:
        return {"ok": False, "status_code": "EMPTY_ID", "error": "ID сессии не может быть пустым"}

    ls_env = get_active_antigravity_ls_env()
    if not ls_env or not ls_env.get("ANTIGRAVITY_LS_ADDRESS"):
        return {
            "ok": False,
            "status_code": "OFFLINE",
            "error": "Antigravity перезагружается (language_server не обнаружен)"
        }

    port = ls_env.get("port") or ls_env.get("ANTIGRAVITY_LS_ADDRESS", "").split(":")[-1]
    retcode, stdout, stderr = run_agentapi_command(["get-conversation-metadata", conv_id], timeout=10)
    if retcode == 0:
        try:
            from native_health import strict_loads
            data = strict_loads(stdout)
            if not isinstance(data,dict) or "error" in data:raise ValueError("NATIVE_METADATA_ERROR_ENVELOPE")
            meta = data["response"]["conversationMetadata"]["metadata"]
            if not isinstance(meta,dict) or not isinstance(meta.get("projectId"),str) or not meta["projectId"]:raise ValueError("NATIVE_METADATA_SCHEMA_UNVERIFIED")
            workspaces = meta.get("workspaceUris")
            if not isinstance(workspaces,list) or not workspaces or any(not isinstance(value,str) or not value for value in workspaces):raise ValueError("NATIVE_METADATA_SCHEMA_UNVERIFIED")
            _LAST_DISCOVERED_ORCH_ID = None
            return {
                "ok": True,
                "status_code": "ONLINE",
                "conversation_id": conv_id,
                "workspaces": workspaces,
                "meta": meta,
                "port": port
            }
        except Exception:
            return {"ok": False, "status_code": "METADATA_UNVERIFIED", "conversation_id": conv_id, "error": "NATIVE_METADATA_UNVERIFIED", "port": port}
    else:
        err_msg = stderr or stdout
        try:
            err_json = json.loads(err_msg)
            err_text = err_json.get("error", err_msg)
        except Exception:
            err_text = err_msg

        if any(k in err_text.lower() for k in ["unavailable", "dial tcp", "connectex", "connection refused"]):
            status_code = "CONNECT_ERROR"
            clean_err = f"Ошибка подключения к порту {port}"
        elif any(k in err_text.lower() for k in ["not found", "code = notfound", "unknown conversation"]):
            status_code = "NOT_FOUND"
            clean_err = "Сессия с таким ID не найдена в Antigravity"
            if check_discovery:
                _LAST_DISCOVERED_ORCH_ID = find_latest_orchestrator_conversation()
        else:
            status_code = "ERROR"
            clean_err = err_text[:80]

        return {
            "ok": False,
            "status_code": status_code,
            "error": clean_err,
            "raw_error": err_text,
            "port": port,
            "discovered_id": _LAST_DISCOVERED_ORCH_ID if check_discovery else None
        }


def send_to_orchestrator(text: str, conv_id: Optional[str] = None) -> dict:
    text = text.strip()
    if not text:
        return {"ok": False, "error": "Текст сообщения пуст"}
    if not conv_id:
        cfg = get_orchestrator_config()
        conv_id = cfg.get("conversation_id", DEFAULT_ORCHESTRATOR_ID)

    retcode, stdout, stderr = run_agentapi_command([
        "send-message",
        "--title=Telegram Owner Input",
        conv_id,
        text
    ], timeout=15)

    # A prose error cannot prove non-delivery or authorize another destination.
    # Owner may validate and bind a new conversation explicitly with /set_orchestrator.
    auto_rebound = False

    # Log to ORCHESTRATOR_INBOX_PATH for complete traceability
    try:
        entry = {
            "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "conversation_id": conv_id,
            "text": text,
            "returncode": retcode,
            "output": stdout or stderr,
            "auto_rebound": auto_rebound
        }
        STATE_ROOT.mkdir(parents=True, exist_ok=True)
        with ORCHESTRATOR_INBOX_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass

    if retcode == 0:
        from native_health import strict_loads
        from native_ack import parse_echo
        try:
            receipt=parse_echo(strict_loads(stdout),conv_id,text)
        except (ValueError,TypeError):
            return {"ok": False, "conversation_id": conv_id, "error": "NATIVE_ACK_UNVERIFIED", "completion_scope": "native_api_acceptance_unverified"}
        return {"ok": True, "conversation_id": conv_id, "receipt": receipt, "auto_rebound": auto_rebound, "completion_scope": "native_api_acceptance_only", "execution_observed": False}
    else:
        return {"ok": False, "conversation_id": conv_id, "error": "NATIVE_SEND_UNCERTAIN"}


# =========================================================================
# Dynamic Multi-Project Registry
# =========================================================================

def get_all_projects() -> Dict[str, dict]:
    cfg = load_config()
    companions = cfg.get("browser", {}).get("companions", {})

    seen_data = {}
    if SEEN_PACKETS_PATH.is_file():
        try:
            seen_data = json.loads(SEEN_PACKETS_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass

    reg_projects = {}
    if PROJECT_REGISTRY_PATH.is_file():
        try:
            reg_data = json.loads(PROJECT_REGISTRY_PATH.read_text(encoding="utf-8"))
            for p in reg_data.get("projects", []):
                p_id = p.get("project_id", "")
                p_name = p.get("logical_name", p_id)
                for alias in [p_id.lower(), p_name.lower()] + [a.lower() for a in p.get("aliases", [])]:
                    reg_projects[alias] = p
        except Exception:
            pass

    st = get_standby_state()
    proj_st = st.get("projects", {})

    all_keys = list(companions.keys())
    for k in seen_data.keys():
        if k not in all_keys:
            all_keys.append(k)

    res = {}
    for key in all_keys:
        comp_info = companions.get(key, {})
        p = seen_data.get(key, {})
        is_p = proj_st.get(key, {}).get("is_paused", False) or p.get("turnState") == "PAUSED_BY_OWNER"
        display_name = comp_info.get("name") or reg_projects.get(key.lower(), {}).get("logical_name") or key.upper()

        icon = "📁"
        k_lower = key.lower()
        if "h10" in k_lower or "cardio" in k_lower:
            icon = "🏃"
        elif "vitalis" in k_lower or "huawei" in k_lower or "health" in k_lower:
            icon = "🧬"
        elif "call" in k_lower or "android" in k_lower or "phone" in k_lower:
            icon = "📱"
        elif "edge" in k_lower or "switch" in k_lower:
            icon = "⚡"
        elif "youtube" in k_lower or "gemini" in k_lower:
            icon = "▶️"

        p_path = comp_info.get("projectPath")
        route = "-"
        owner_dec_req = False
        owner_reason = ""
        goal = ""
        wid = ""
        step_idx = "?"
        step_time_rel = ""
        if p_path:
            p_dir = Path(p_path)
            na_p = p_dir / ".agy" / "NEXT_ACTION.json"
            wi_p = p_dir / ".agy" / "WORK_ITEM.json"
            if na_p.is_file():
                try:
                    na_d = json.loads(na_p.read_text(encoding="utf-8"))
                    route = na_d.get("route") or "null (завершено/ожидает)"
                    owner_dec_req = na_d.get("owner_decision_required", False)
                    owner_reason = na_d.get("owner_decision_reason", "")
                except Exception:
                    pass
            if wi_p.is_file():
                try:
                    wi_d = json.loads(wi_p.read_text(encoding="utf-8"))
                    goal = wi_d.get("goal", "")
                    wid = wi_d.get("work_item_id", "")
                except Exception:
                    pass

        c_cid = comp_info.get("antigravityConversationId")
        if c_cid:
            tr_p = BRAIN_ROOT / c_cid / ".system_generated" / "logs" / "transcript.jsonl"
            if tr_p.is_file():
                try:
                    sz = tr_p.stat().st_size
                    rb = min(sz, 32768)
                    with open(tr_p, "rb") as tf:
                        tf.seek(sz - rb)
                        lines_t = tf.read().decode("utf-8", errors="ignore").splitlines()
                    for lt in reversed(lines_t):
                        lt = lt.strip()
                        if lt:
                            try:
                                td = json.loads(lt)
                                step_idx = td.get("step_index", "?")
                                s_dt_str = td.get("created_at", "")
                                if s_dt_str:
                                    s_dt = dt.datetime.fromisoformat(s_dt_str.replace("Z", "+00:00"))
                                    sec_d = max(0, int((dt.datetime.now(dt.timezone.utc) - s_dt).total_seconds()))
                                    if sec_d < 60:
                                        step_time_rel = f"{sec_d}с назад"
                                    elif sec_d < 3600:
                                        step_time_rel = f"{sec_d//60}м назад"
                                    else:
                                        step_time_rel = f"{sec_d//3600}ч назад"
                                break
                            except Exception:
                                pass
                except Exception:
                    pass

        res[key] = {
            "key": key,
            "name": display_name,
            "icon": icon,
            "url_pattern": comp_info.get("urlPattern", ""),
            "state": p.get("turnState", "READY_FOR_CONTEXT"),
            "packet": p.get("fileName") or p.get("lastPacketId") or "нет",
            "nudges": p.get("nudgeRetries", 0),
            "last_pushed": p.get("lastPushedAt", "-"),
            "is_paused": is_p,
            "route": route,
            "goal": goal,
            "work_item_id": wid,
            "step_index": step_idx,
            "step_time_rel": step_time_rel,
            "owner_decision_required": owner_dec_req,
            "owner_decision_reason": owner_reason
        }
    return res


def get_projects_summary() -> dict:
    return get_all_projects()


def normalize_project_key(project_key: str) -> Optional[str]:
    p_lower = (project_key or "").lower().strip()
    if not p_lower:
        return None
    projects = get_all_projects()
    if p_lower in projects:
        return p_lower
    for k, p in projects.items():
        if p_lower == k.lower():
            return k
        if p_lower in p.get("name", "").lower():
            return k
    if p_lower in ("х10", "h-10", "athlete"):
        return "h10"
    if p_lower in ("виталис", "huawei", "health"):
        return "vitalis"
    return None


# =========================================================================
# Cycle and State Management
# =========================================================================

def get_standby_state() -> dict:
    return runtime_snapshot()


def _sync_standby_file(enabled: bool, mode: str, reason: str):
    try:
        data = {
            "is_standby": enabled,
            "mode": mode if enabled else "NORMAL",
            "reason": reason,
            "updated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()
        }
        STANDBY_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STANDBY_STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(STANDBY_STATE_PATH)
    except Exception:
        pass


def set_standby_state(enabled: bool, mode: str = "MAN_IN_THE_MIDDLE", reason: str = "") -> dict:
    res = runtime_owner_set(enabled, mode, reason)
    _sync_standby_file(enabled, mode, reason)
    return res


def pause_pipeline(mode: str = "MAN_IN_THE_MIDDLE", reason: str = "") -> dict:
    return set_standby_state(True, mode=mode, reason=reason)


def resume_pipeline(expected_epoch=None) -> dict:
    res = runtime_owner_set(False, all_projects=True, expected_epoch=expected_epoch)
    _sync_standby_file(False, "NORMAL", "EXPLICIT_OWNER_RESUME")
    return res


def pause_project(project_key: str, reason: str = "") -> dict:
    return runtime_owner_set(True, "MANUAL", reason, project=project_key)


def resume_project(project_key: str, expected_epoch=None) -> dict:
    res = runtime_owner_set(False, project=project_key, expected_epoch=expected_epoch)
    try:
        st = get_standby_state()
        if not st.get("is_standby"):
            _sync_standby_file(False, "NORMAL", "EXPLICIT_OWNER_RESUME")
    except Exception:
        pass
    return res


def get_directive() -> dict:
    if OWNER_DIRECTIVE_PATH.is_file():
        try:
            return json.loads(OWNER_DIRECTIVE_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"active": False, "text": ""}


def set_directive(text: str) -> dict:
    OWNER_DIRECTIVE_PATH.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "active": True,
        "text": text.strip(),
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "author": "Telegram Bot (Owner)"
    }
    tmp = OWNER_DIRECTIVE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(OWNER_DIRECTIVE_PATH)
    return data


def clear_directive() -> dict:
    data = {
        "active": False,
        "text": "",
        "updated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "author": "Telegram Bot (Owner)"
    }
    tmp = OWNER_DIRECTIVE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(OWNER_DIRECTIVE_PATH)
    return data


# =========================================================================
# Universal Interactive Input State Machine
# =========================================================================

def get_pending_input(chat_id: str) -> Optional[dict]:
    if PENDING_INPUT_PATH.is_file():
        try:
            data = json.loads(PENDING_INPUT_PATH.read_text(encoding="utf-8"))
            if str(data.get("chat_id")) == str(chat_id):
                if time.time() < data.get("expires_at", 0):
                    return data
                else:
                    PENDING_INPUT_PATH.unlink(missing_ok=True)
        except Exception:
            pass
    if PENDING_REPLY_PATH.is_file():
        try:
            data = json.loads(PENDING_REPLY_PATH.read_text(encoding="utf-8"))
            if str(data.get("chat_id")) == str(chat_id):
                if time.time() < data.get("expires_at", 0):
                    return {"chat_id": chat_id, "mode": "companion_reply", "target": data.get("project", "")}
                else:
                    PENDING_REPLY_PATH.unlink(missing_ok=True)
        except Exception:
            pass
    return None


def set_pending_input(chat_id: str, mode: str, target: str = "", metadata: Optional[dict] = None) -> None:
    try:
        data = {
            "chat_id": str(chat_id),
            "mode": mode,
            "target": target,
            "metadata": metadata or {},
            "created_at": time.time(),
            "expires_at": time.time() + 600
        }
        STATE_ROOT.mkdir(parents=True, exist_ok=True)
        tmp = PENDING_INPUT_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(PENDING_INPUT_PATH)
    except Exception:
        pass


def clear_pending_input() -> None:
    try:
        PENDING_INPUT_PATH.unlink(missing_ok=True)
        PENDING_REPLY_PATH.unlink(missing_ok=True)
    except Exception:
        pass


def get_pending_reply(chat_id: str) -> Optional[str]:
    p = get_pending_input(chat_id)
    if p and p.get("mode") == "companion_reply":
        return p.get("target")
    return None


def set_pending_reply(chat_id: str, project: str) -> None:
    set_pending_input(chat_id, "companion_reply", project)


def clear_pending_reply() -> None:
    clear_pending_input()


def get_cached_text(chat_id: str) -> Optional[str]:
    if not CACHED_TEXT_PATH.is_file():
        return None
    try:
        data = json.loads(CACHED_TEXT_PATH.read_text(encoding="utf-8"))
        if str(data.get("chat_id")) == str(chat_id):
            if time.time() < data.get("expires_at", 0):
                return str(data.get("text", ""))
            else:
                CACHED_TEXT_PATH.unlink(missing_ok=True)
    except Exception:
        pass
    return None


def save_cached_text(chat_id: str, text: str) -> None:
    try:
        data = {
            "chat_id": str(chat_id),
            "text": text,
            "created_at": time.time(),
            "expires_at": time.time() + 600
        }
        STATE_ROOT.mkdir(parents=True, exist_ok=True)
        tmp = CACHED_TEXT_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(CACHED_TEXT_PATH)
    except Exception:
        pass


def clear_cached_text() -> None:
    try:
        CACHED_TEXT_PATH.unlink(missing_ok=True)
    except Exception:
        pass


def get_waiting_owner_gate_project() -> Optional[str]:
    if not SEEN_PACKETS_PATH.is_file():
        return None
    try:
        data = json.loads(SEEN_PACKETS_PATH.read_text(encoding="utf-8"))
        waiting = [k for k, v in data.items() if isinstance(v, dict) and v.get("turnState") == "AWAITING_OWNER_INPUT"]
        if len(waiting) == 1:
            return waiting[0]
    except Exception:
        pass
    return None


def send_to_companion(project_key: str, message_text: str) -> dict:
    from telegram_bot_integration import send_companion
    return send_companion(globals(), project_key, message_text)


def format_duration(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds} сек"
    mins = seconds // 60
    secs = seconds % 60
    if mins < 60:
        return f"{mins}м {secs}с"
    hours = mins // 60
    mins = mins % 60
    return f"{hours}ч {mins}м"


def is_antigravity_running() -> Optional[int]:
    try:
        import psutil
        for p in psutil.process_iter(['pid', 'name']):
            try:
                if (p.info['name'] or '').lower() == 'antigravity.exe':
                    return p.info['pid']
            except Exception:
                pass
    except Exception:
        pass
    return None


def get_services_status() -> dict:
    status = {
        "antigravity": is_antigravity_running(),
        "companion_bridge": None,
        "action_bridge": None,
        "process_guard": None,
        "telegram_bot": os.getpid()
    }
    pids = {}
    if SUPERVISOR_PIDS_PATH.is_file():
        try:
            pids.update(json.loads(SUPERVISOR_PIDS_PATH.read_text(encoding="utf-8")))
        except Exception:
            pass
    for k in ["companion_bridge", "action_bridge", "process_guard"]:
        pid_file = LOG_DIR / f"{k}.pid"
        if pid_file.is_file():
            try:
                pids[k] = int(pid_file.read_text(encoding="utf-8").strip())
            except Exception:
                pass
        pid = pids.get(k)
        if pid:
            try:
                handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
                if handle:
                    exit_code = ctypes.c_ulong()
                    ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
                    ctypes.windll.kernel32.CloseHandle(handle)
                    if exit_code.value == 259:
                        status[k] = pid
            except Exception:
                pass
    return status


def execute_supervisor_ensure() -> dict:
    from telegram_bot_integration import ensure_supervisor
    return ensure_supervisor(globals())


def execute_safe_sleep() -> None:
    pause_pipeline(mode="PRE_SLEEP", reason="Штатный перевод ПК в спящий режим по Telegram-команде")
    time.sleep(1.0)
    cmd = [
        "powershell", "-NoProfile", "-Command",
        "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)"
    ]
    subprocess.Popen(cmd, creationflags=CREATE_NO_WINDOW)


# =========================================================================
# UI Keyboards & Screen Formatters
# =========================================================================

def build_dashboard_text() -> str:
    st = get_standby_state()
    is_paused = st.get("is_standby", False)
    mode = st.get("mode", "NORMAL")
    reason = st.get("reason", "")
    paused_at = st.get("paused_at_utc")

    pause_dur_str = "-"
    if is_paused and paused_at:
        try:
            p_dt = dt.datetime.fromisoformat(paused_at.replace("Z", "+00:00"))
            cur_sec = int((dt.datetime.now(dt.timezone.utc) - p_dt).total_seconds())
            pause_dur_str = format_duration(max(0, cur_sec))
        except Exception:
            pass
    elif not is_paused:
        last_dur = st.get("last_pause_duration_sec", 0)
        pause_dur_str = f"Предыдущая пауза: {format_duration(last_dur)}"

    services = get_services_status()
    projects = get_all_projects()
    directive = get_directive()
    orch_cfg = get_orchestrator_config()
    orch_id = orch_cfg.get("conversation_id", "")
    orch_short = orch_id[:8] + "..." if len(orch_id) > 8 else (orch_id or "не задан")

    status_badge = "⏸ <b>ПАУЗА (STANDBY)</b>" if is_paused else "🟢 <b>АКТИВЕН (В РАБОТЕ)</b>"

    ag_icon = f"🟢 PID {services['antigravity']}" if services.get('antigravity') else "🔴 Не запущен"
    cb_icon = f"🟢 PID {services['companion_bridge']}" if services['companion_bridge'] else "🔴 Остановлен"
    ab_icon = f"🟢 PID {services['action_bridge']}" if services['action_bridge'] else "🔴 Остановлен"
    pg_icon = f"🟢 PID {services['process_guard']}" if services['process_guard'] else "🔴 Остановлен"
    tb_icon = f"🟢 PID {os.getpid()}"

    dir_text = "<i>нет активной директивы</i>"
    if directive.get("active") and directive.get("text"):
        d_val = directive.get("text")
        if len(d_val) > 100:
            d_val = d_val[:97] + "..."
        dir_text = f"🎯 <b>«{d_val}»</b>"

    def state_badge(s: str, is_p: bool) -> str:
        if is_p:
            return "⏸ <b>ПАУЗА</b>"
        elif s in ("WAITING_FOR_RESPONSE", "AWAITING_COMPANION_PACKET"):
            return "⏳ Думает ChatGPT"
        elif s == "ACTION_PACKET_DETECTED":
            return "📦 Пакет готов"
        elif s == "AWAITING_OWNER_INPUT":
            return "🛑 Ожидает решения"
        elif s == "READY_FOR_CONTEXT":
            return "⚙️ Исполнение в IDE"
        elif s == "COMPANION_BLOCKED":
            return "⚠️ Блокер"
        elif s == "COMPANION_ERROR":
            return "❌ Ошибка сети/веб"
        elif s == "CHAT_MAX_LENGTH_REACHED":
            return "🛑 Лимит чата ChatGPT"
        elif s == "COOLDOWN":
            return "💤 Cooldown"
        return f"[{s}]"

    proj_lines = []
    for k, p in projects.items():
        icon = p.get("icon", "📁")
        name = p.get("name", k)
        st_b = state_badge(p['state'], p['is_paused'])
        route = p.get("route", "-")
        s_idx = p.get("step_index", "?")
        s_time = p.get("step_time_rel", "")
        time_suffix = f" ({s_time})" if s_time else ""

        extra = []
        extra.append(f"   ├ <i>Агент:</i> Шаг {s_idx}{time_suffix} | <code>{route}</code>")
        if p.get("owner_decision_required"):
            reason_short = (p.get('owner_decision_reason', '')[:50] + "...") if len(p.get('owner_decision_reason', '')) > 50 else p.get('owner_decision_reason', '')
            extra.append(f"   └ 🛑 <b>Ожидает владельца:</b> <i>{reason_short}</i>")
        else:
            pkt = p['packet']
            if len(pkt) > 35:
                pkt = pkt[:32] + "..."
            extra.append(f"   └ <i>Компаньон:</i> <code>{pkt}</code>")

        proj_lines.append(f" {icon} <b>{name}:</b> {st_b}\n" + "\n".join(extra))

    lines = [
        f"🎮 <b>ПАНЕЛЬ УПРАВЛЕНИЯ ЦИКЛОМ (AGENTIC DASH)</b>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"<b>Статус системы:</b> {status_badge}",
        f"<b>Оркестратор AGY:</b> 🤖 <code>{orch_short}</code>",
        f"<b>Режим:</b> <code>{mode}</code> | <i>{pause_dur_str}</i>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"🛠 <b>Службы комплекса:</b>",
        f" • Antigravity IDE: {ag_icon}",
        f" • Companion Bridge: {cb_icon}",
        f" • Action Bridge: {ab_icon}",
        f" • Process Guard: {pg_icon}",
        f" • Telegram Bot: {tb_icon}",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"📁 <b>Проекты ({len(projects)}):</b>",
        *proj_lines,
        f"━━━━━━━━━━━━━━━━━━━━",
        f"🎯 <b>Директива владельца:</b>\n{dir_text}",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"🕒 <i>{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} (автономный режим)</i>"
    ]
    return "\n".join(lines)


def build_main_keyboard() -> dict:
    st = get_standby_state()
    is_paused = st.get("is_standby", False)
    projects = get_all_projects()
    proj_count = len(projects)

    if is_paused:
        pause_all_btn = {"text": "▶️ Возобновить ВСЁ", "callback_data": "cb_resume"}
    else:
        pause_all_btn = {"text": "⏸ Полная пауза (MitM)", "callback_data": "cb_pause"}

    return {
        "inline_keyboard": [
            [
                {"text": "📊 Дашборд", "callback_data": "cb_status"},
                {"text": "⚡ Лимит ChatGPT", "callback_data": "cb_chatgpt_limit"}
            ],
            [
                {"text": f"📁 Проекты ({proj_count})", "callback_data": "cb_projects_list"},
                {"text": "🤖 Оркестратор Antigravity", "callback_data": "cb_orchestrator_menu"}
            ],
            [
                {"text": "🎯 Директива", "callback_data": "cb_directive_view"},
                pause_all_btn
            ],
            [
                {"text": "🔄 Рестарт служб", "callback_data": "cb_restart"},
                {"text": "🌙 Спящий режим ПК", "callback_data": "cb_sleep_prompt"}
            ],
            [
                {"text": "📖 Справка по командам", "callback_data": "cb_help"}
            ]
        ]
    }


def build_projects_menu_text() -> str:
    projects = get_all_projects()
    lines = [
        f"📁 <b>КАТАЛОГ ПРОЕКТОВ ЦИКЛА ({len(projects)})</b>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"Выберите проект для управления, отправки ответа компаньону в ChatGPT или проверки статуса:"
    ]
    return "\n".join(lines)


def build_projects_menu_keyboard() -> dict:
    projects = get_all_projects()
    st = get_standby_state()
    is_paused = st.get("is_standby", False)
    rows = []

    for key, p in projects.items():
        icon = p.get("icon", "📁")
        name = p.get("name", key)
        badge = "⏸" if p.get("is_paused") else "▶️"
        rows.append([{"text": f"{icon} {name} [{badge}]", "callback_data": f"cb_proj_card_{key}"}])

    if is_paused:
        rows.append([{"text": "▶️ Возобновить ВСЕ проекты", "callback_data": "cb_resume"}])
    else:
        rows.append([{"text": "⏸ Пауза ВСЕХ проектов", "callback_data": "cb_pause"}])

    rows.append([{"text": "🔙 В главное меню", "callback_data": "cb_refresh"}])
    return {"inline_keyboard": rows}


def build_project_detail_text(project_key: str) -> str:
    projects = get_all_projects()
    p = projects.get(project_key)
    if not p:
        return f"❌ Проект <code>{project_key}</code> не найден."

    icon = p.get("icon", "📁")
    name = p.get("name", project_key)
    state = p.get("state", "READY_FOR_CONTEXT")
    state_display = {
        "READY_FOR_CONTEXT": "⚙️ Исполнение в IDE (Antigravity)",
        "AWAITING_COMPANION_PACKET": "⏳ Думает ChatGPT",
        "WAITING_FOR_RESPONSE": "⏳ Думает ChatGPT",
        "AWAITING_OWNER_INPUT": "🛑 Ожидает решения владельца",
        "ACTION_PACKET_DETECTED": "📦 Пакет готов к передаче",
        "COMPANION_BLOCKED": "⚠️ Блокер компаньона",
        "COMPANION_ERROR": "❌ Ошибка сети/веб",
        "CHAT_MAX_LENGTH_REACHED": "🛑 Превышен лимит чата ChatGPT",
        "COOLDOWN": "💤 Cooldown"
    }.get(state, f"<code>{state}</code>")
    is_p = p.get("is_paused", False)
    status_str = "⏸ <b>На паузе</b>" if is_p else "🟢 <b>В работе</b>"

    lines = [
        f"{icon} <b>ПРОЕКТ: {name}</b>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"<b>Статус:</b> {status_str}",
        f"<b>Состояние:</b> {state_display}",
        f"<b>Активный пакет:</b> <code>{p.get('packet')}</code>",
        f"<b>Попыток auto-nudge:</b> {p.get('nudges')}",
        f"<b>Последний handoff:</b> <i>{p.get('last_pushed')}</i>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"💡 <i>Используйте кнопки ниже для управления проектом или отправки ответа компаньону.</i>"
    ]
    return "\n".join(lines)


def build_project_detail_keyboard(project_key: str) -> dict:
    projects = get_all_projects()
    p = projects.get(project_key, {})
    is_p = p.get("is_paused", False)

    toggle_pause_btn = {
        "text": "▶️ Возобновить проект" if is_p else "⏸ Поставить на паузу",
        "callback_data": f"cb_proj_resume_{project_key}" if is_p else f"cb_proj_pause_{project_key}"
    }

    return {
        "inline_keyboard": [
            [
                toggle_pause_btn,
                {"text": "💬 Ответить компаньону", "callback_data": f"cb_reply_prompt_{project_key}"}
            ],
            [
                {"text": "🔄 Обновить статус", "callback_data": f"cb_proj_refresh_{project_key}"}
            ],
            [
                {"text": "🔙 К списку проектов", "callback_data": "cb_projects_list"},
                {"text": "🏠 Главное меню", "callback_data": "cb_refresh"}
            ]
        ]
    }


_LAST_ORCH_VIEW_CACHE: Optional[Tuple[str, dict]] = None
_LAST_ORCH_VIEW_CACHE_TIME: float = 0.0


def build_orchestrator_view(force_refresh: bool = False) -> Tuple[str, dict]:
    global _LAST_ORCH_VIEW_CACHE, _LAST_ORCH_VIEW_CACHE_TIME
    now = time.time()
    if not force_refresh and _LAST_ORCH_VIEW_CACHE and (now - _LAST_ORCH_VIEW_CACHE_TIME < 5.0):
        return _LAST_ORCH_VIEW_CACHE

    cfg = get_orchestrator_config()
    conv_id = cfg.get("conversation_id", "")
    title = cfg.get("title", "Master Orchestrator")

    val_res = validate_conversation_id(conv_id, check_discovery=True)
    port_str = val_res.get("port") or "?"
    discovered_id = val_res.get("discovered_id")

    if val_res.get("ok"):
        status_icon = f"🟢 В сети (порт: {port_str})"
        ws_list = val_res.get("workspaces", [])
        ws_text = "\n".join([f" • <code>{urllib.parse.unquote(w.split('/')[-1])}</code>" for w in ws_list]) if ws_list else " • <i>Рабочие пространства определены</i>"
        extra_info = ""
    else:
        status_code = val_res.get("status_code")
        if status_code == "OFFLINE":
            status_icon = "🔴 Antigravity офлайн / перезапуск"
            ws_text = " • <i>language_server.exe не запущен</i>"
        elif status_code == "CONNECT_ERROR":
            status_icon = f"🔴 Ошибка связи с портом {port_str}"
            ws_text = " • <i>Процесс перезагружается или сменил порт</i>"
        elif status_code == "NOT_FOUND":
            status_icon = "🟡 Сессия завершена / недоступна"
            ws_text = " • <i>Предыдущая сессия закрыта</i>"
        else:
            err_sub = str(val_res.get("error", "Сбой"))[:40]
            status_icon = f"🔴 Ошибка ({err_sub})"
            ws_text = " • <i>Сессия недоступна</i>"

        if discovered_id and discovered_id != conv_id:
            extra_info = (
                f"\n━━━━━━━━━━━━━━━━━━━━\n"
                f"⚡ <b>Обнаружена активная сессия:</b>\n"
                f"<code>{discovered_id}</code>\n"
                f"<i>Нажмите кнопку ниже для быстрой привязки в 1 клик.</i>"
            )
        else:
            extra_info = ""

    lines = [
        f"🤖 <b>ОРКЕСТРАТОР ANTIGRAVITY</b>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"<b>Роль:</b> {title}",
        f"<b>Статус связи (agentapi):</b> {status_icon}",
        f"<b>Conversation ID:</b>\n<code>{conv_id}</code>",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"<b>Рабочие пространства:</b>\n{ws_text}"
    ]
    if extra_info:
        lines.append(extra_info)
    lines.append("━━━━━━━━━━━━━━━━━━━━")
    lines.append("💡 <i>Отправленное сообщение реактивно пробуждает оркестратора в Antigravity и передаётся напрямую в его контекст.</i>")

    text = "\n".join(lines)

    buttons = [
        [{"text": "💬 Написать оркестратору", "callback_data": "cb_orch_send_prompt"}]
    ]
    if discovered_id and discovered_id != conv_id:
        buttons.append([
            {"text": f"⚡ Привязать найденную ({discovered_id[:8]}...)", "callback_data": f"cb_orch_bind_{discovered_id}"}
        ])
    buttons.append([
        {"text": "🆔 Сменить ID", "callback_data": "cb_orch_set_id_prompt"},
        {"text": "🔄 Проверить статус", "callback_data": "cb_orch_refresh"}
    ])
    buttons.append([
        {"text": "🏠 Главное меню", "callback_data": "cb_refresh"}
    ])

    res = (text, {"inline_keyboard": buttons})
    _LAST_ORCH_VIEW_CACHE = res
    _LAST_ORCH_VIEW_CACHE_TIME = now
    return res


def build_orchestrator_text() -> str:
    txt, _ = build_orchestrator_view()
    return txt


def build_orchestrator_keyboard() -> dict:
    _, kb = build_orchestrator_view()
    return kb


def build_input_cancel_keyboard() -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "❌ Отменить ввод", "callback_data": "cb_reply_cancel"}
            ]
        ]
    }


def build_directive_keyboard() -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "❌ Сбросить директиву", "callback_data": "cb_directive_clear"},
                {"text": "🔙 В главное меню", "callback_data": "cb_refresh"}
            ]
        ]
    }


def build_sleep_confirm_keyboard() -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "✅ ДА, перевести в СОН", "callback_data": "cb_sleep_confirm"},
                {"text": "❌ Отмена", "callback_data": "cb_sleep_cancel"}
            ]
        ]
    }


def get_command_reference_text() -> str:
    return (
        f"📖 <b>РУКОВОДСТВО ПО КОМАНДАМ УПРАВЛЕНИЯ ЦИКЛОМ</b>\n\n"
        f"Управление автономным циклом и оркестратором Antigravity со смартфона:\n\n"
        f"📊 <b>Мониторинг и проекты:</b>\n"
        f"• <code>/status</code> — сводный дашборд цикла, PIDs служб, активный оркестратор и фазы проектов.\n"
        f"• <code>/projects</code> — каталог всех проектов в цикле с возможностью открыть карточку любого проекта.\n"
        f"• <code>/project &lt;имя&gt;</code> — детальная карточка конкретного проекта (напр. <code>/project h10</code>).\n"
        f"• <code>/ping</code> — проверка отклика и времени бота.\n\n"
        f"🤖 <b>Оркестратор Antigravity:</b>\n"
        f"• <code>/orchestrator &lt;текст&gt;</code> (или <code>/agy &lt;текст&gt;</code>) — передать текстовую команду напрямую агенту-оркестратору Antigravity.\n"
        f"• <code>/orchestrator</code> — открыть панель управления оркестратором.\n"
        f"• <code>/set_orchestrator &lt;conversation_id&gt;</code> — привязать новый ID сессии Antigravity с проверкой доступности.\n\n"
        f"💬 <b>Ответ компаньону ChatGPT:</b>\n"
        f"• <code>/reply &lt;текст&gt;</code> — отправить ответ в чат ChatGPT (если проект ждёт решения — уйдёт сразу, иначе предложит выбор).\n"
        f"• <code>/reply_h10 &lt;текст&gt;</code> / <code>/reply_vitalis &lt;текст&gt;</code> — прямой ответ в выбранный чат.\n\n"
        f"⏸ <b>Пауза и возобновление:</b>\n"
        f"• <code>/pause</code> — глобальная пауза всех проектов (режим MitM).\n"
        f"• <code>/resume</code> — возобновление работы всех проектов.\n"
        f"• <code>/pause &lt;проект&gt;</code> / <code>/resume &lt;проект&gt;</code> — изолированная пауза одного проекта (напр. <code>/pause h10</code>).\n\n"
        f"🎯 <b>Стратегическая директива:</b>\n"
        f"• <code>/directive &lt;текст&gt;</code> — задать обязательное указание владельца для всех промптов компаньона.\n"
        f"• <code>/directive_clear</code> — снять директиву.\n\n"
        f"🛠 <b>Службы и ПК:</b>\n"
        f"• <code>/restart</code> — самоисцеление: супервизор проверяет все службы и поднимает упавшие.\n"
        f"• <code>/sleep</code> — безопасный перевод ПК в спящий режим.\n"
        f"• <code>/help</code> — показать это справочное меню.\n\n"
        f"💡 <i>Бот также понимает простые русские фразы: «статус», «проекты», «оркестратор», «пауза», «пуск», «сон».</i>"
    )


# =========================================================================
# Command Dispatcher
# =========================================================================

def handle_command(chat_id: str, text: str, message_id: Optional[int] = None) -> None:
    raw = text.strip()
    import re

    # 1. Check if there is an active interactive input mode
    pending = get_pending_input(chat_id)
    if pending:
        mode = pending.get("mode")
        target = pending.get("target", "")

        if raw.lower() in ("/cancel", "отмена", "отменить", "cancel"):
            clear_pending_input()
            clear_cached_text()
            send_message(chat_id, "❌ Режим ввода отменён.", reply_markup=build_main_keyboard())
            return

        # Check if the input is a valid response (not another slash command, or explicit input command)
        is_override_cmd = raw.startswith("/") and not raw.startswith(("/reply", "/orchestrator", "/agy", "/set_orchestrator"))
        if not is_override_cmd:
            clear_pending_input()
            clear_cached_text()

            if mode == "orchestrator":
                send_message(chat_id, "⏳ <b>Передача сообщения оркестратору Antigravity...</b>")
                res = send_to_orchestrator(raw, target)
                if res.get("ok"):
                    conv_id = res.get("conversation_id", target)
                    send_message(
                        chat_id,
                        f"✅ <b>API принял команду для оркестратора.</b>\n\n"
                        f"🆔 <b>Сессия:</b> <code>{conv_id}</code>\n"
                        f"💬 <b>Текст:</b> <i>«{raw}»</i>\n\n"
                        f"• Исполнение не подтверждено.",
                        reply_markup=build_orchestrator_keyboard()
                    )
                else:
                    send_message(
                        chat_id,
                        f"❌ <b>Ошибка передачи оркестратору:</b>\n\n<code>{res.get('error')}</code>",
                        reply_markup=build_orchestrator_keyboard()
                    )
                return

            elif mode == "set_orchestrator":
                new_id = raw.strip()
                send_message(chat_id, f"⏳ <b>Проверка сессии <code>{new_id}</code> в Antigravity...</b>")
                val_res = validate_conversation_id(new_id)
                if val_res.get("ok"):
                    workspaces = val_res.get("workspaces", [])
                    set_orchestrator_config(new_id, workspaces=workspaces)
                    ws_text = "\n".join([f" • <code>{w.split('/')[-1]}</code>" for w in workspaces]) if workspaces else " • <i>(определены)</i>"
                    send_message(
                        chat_id,
                        f"✅ <b>Conversation ID оркестратора успешно обновлён!</b>\n\n"
                        f"🆔 <b>Новый ID:</b> <code>{new_id}</code>\n"
                        f"📁 <b>Рабочие пространства:</b>\n{ws_text}",
                        reply_markup=build_orchestrator_keyboard()
                    )
                else:
                    send_message(
                        chat_id,
                        f"❌ <b>Сессия не найдена:</b>\n\n<code>{val_res.get('error')}</code>\n\n"
                        f"Убедитесь, что указан корректный UUID существующей сессии Antigravity.",
                        reply_markup=build_orchestrator_keyboard()
                    )
                return

            elif mode == "companion_reply":
                proj_key = normalize_project_key(target) or target
                projects = get_all_projects()
                p = projects.get(proj_key, {})
                proj_label = p.get("name", proj_key.upper())
                send_message(chat_id, f"⏳ <b>Отправка ответа в ChatGPT ({proj_label})...</b>")
                res = send_to_companion(proj_key, raw)
                if res.get("ok"):
                    send_message(
                        chat_id,
                        f"✅ <b>Ответ успешно отправлен в чат {proj_label}!</b>\n\n"
                        f"• Сообщение передано в ChatGPT через Chrome DevTools.\n"
                        f"• Флаг ожидания решения снят, компаньон продолжает работу.",
                        reply_markup=build_project_detail_keyboard(proj_key)
                    )
                else:
                    send_message(
                        chat_id,
                        f"❌ <b>Ошибка при отправке в ChatGPT ({proj_label}):</b>\n\n"
                        f"<code>{res.get('error')}</code>",
                        reply_markup=build_project_detail_keyboard(proj_key)
                    )
                return
        else:
            clear_pending_input()

    # 2. Command normalization
    normalized = re.sub(r'^[^\w/]+', '', raw).strip()
    parts = normalized.split(maxsplit=1)
    cmd = parts[0].lower() if parts else ""
    arg = parts[1].strip() if len(parts) > 1 else ""

    # Check natural language phrases
    full_lower = normalized.lower()
    if full_lower in ("пауза h10", "пауза х10"):
        cmd, arg = "/pause", "h10"
    elif full_lower in ("пуск h10", "возобновить h10"):
        cmd, arg = "/resume", "h10"
    elif full_lower in ("пауза vitalis", "пауза виталис"):
        cmd, arg = "/pause", "vitalis"
    elif full_lower in ("пуск vitalis", "возобновить vitalis"):
        cmd, arg = "/resume", "vitalis"
    elif full_lower in ("ответить vitalis", "ответить виталис", "ответ vitalis", "ответ виталис"):
        cmd, arg = "/reply", "vitalis"
    elif full_lower in ("ответить h10", "ответить х10", "ответ h10", "ответ х10"):
        cmd, arg = "/reply", "h10"
    elif full_lower in ("полная пауза (mitm)", "полная пауза", "пауза всё", "пауза все"):
        cmd = "/pause"
    elif full_lower in ("возобновить всё", "возобновить все", "пуск всё", "пуск все"):
        cmd = "/resume"
    elif full_lower in ("рестарт служб", "рестарт", "перезапуск"):
        cmd = "/restart"
    elif full_lower in ("спящий режим пк", "спящий режим", "сон"):
        cmd = "/sleep"
    elif full_lower in ("оркестратор", "агент", "antigravity"):
        cmd = "/orchestrator"
    elif full_lower in ("проекты", "список проектов", "каталог проектов"):
        cmd = "/projects"
    elif full_lower in ("лимит", "лимиты", "остаток", "usage", "limit", "проверить лимит"):
        cmd = "/limit"

    # Route: Start / Help / Reference
    if cmd in ("/start", "/help", "/menu", "помощь", "меню", "старт"):
        ref = get_command_reference_text()
        send_message(chat_id, ref)
        dash = build_dashboard_text()
        send_message(chat_id, dash, reply_markup=build_main_keyboard())

    # Route: Status / Dashboard
    elif cmd in ("/status", "статус", "/dash", "дэш", "дашборд"):
        dash = build_dashboard_text()
        send_message(chat_id, dash, reply_markup=build_main_keyboard())

    # Route: ChatGPT Weekly Limit Check
    elif cmd in ("/limit", "/usage"):
        send_message(chat_id, "⏳ <b>Проверка недельного лимита ChatGPT...</b>")
        import chatgpt_usage_monitor as um
        state = um.load_saved_state()
        live = um.extract_live_usage()
        if live and live.get("percent") is not None:
            pct = live["percent"]
            rem_txt = live.get("remainingText") or f"Остается {pct}%"
            res_txt = live.get("resetText") or "—"
            avail = live.get("resetsAvailable") if live.get("resetsAvailable") is not None else "—"
            now_str = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            state["percent"] = pct
            state["remainingText"] = rem_txt
            state["resetText"] = res_txt
            state["resetsAvailable"] = avail
            state["lastCheckedAt"] = now_str
            um.save_state(state)
            icon = "🟢" if pct > 0 else "🔴"
            msg = (
                f"⚡ <b>ТЕКУЩИЙ ЛИМИТ CHATGPT</b>\n\n"
                f"{icon} <b>Недельный лимит:</b> <code>{pct}%</code> ({rem_txt})\n"
                f"🔄 <b>Доступно сбросов:</b> <code>{avail}</code>\n"
                f"⏳ <b>Сброс через:</b> <code>{res_txt}</code>\n"
                f"🕒 <b>Обновлено:</b> {now_str}\n\n"
                f"💡 <i>Отслеживание активно: бот пришлёт push при сбросе лимита.</i>"
            )
        else:
            pct = state.get("percent", 0)
            rem_txt = state.get("remainingText", "Остается 0%")
            last_chk = state.get("lastCheckedAt", "—")
            msg = (
                f"⚡ <b>СОХРАНЁННЫЙ ЛИМИТ CHATGPT</b>\n\n"
                f"🔴 <b>Последнее значение:</b> <code>{pct}%</code> ({rem_txt})\n"
                f"🕒 <b>Проверено в:</b> {last_chk}\n"
                f"⚠️ <i>Браузер закрыт или вкладка недоступна в CDP. При открытии браузера значение обновится автоматически.</i>"
            )
        send_message(chat_id, msg, reply_markup=build_main_keyboard())

    # Route: Projects Catalog
    elif cmd in ("/projects", "проекты"):
        txt = build_projects_menu_text()
        send_message(chat_id, txt, reply_markup=build_projects_menu_keyboard())

    # Route: Specific Project Detail (/project <key> or /h10, /vitalis)
    elif cmd in ("/project", "/proj"):
        proj_key = normalize_project_key(arg)
        if proj_key:
            txt = build_project_detail_text(proj_key)
            send_message(chat_id, txt, reply_markup=build_project_detail_keyboard(proj_key))
        else:
            send_message(chat_id, f"Укажите проект: <code>/project &lt;имя&gt;</code>\n\nИли выберите из списка <code>/projects</code>.")

    elif cmd in ("/h10", "х10"):
        txt = build_project_detail_text("h10")
        send_message(chat_id, txt, reply_markup=build_project_detail_keyboard("h10"))

    elif cmd in ("/vitalis", "виталис"):
        txt = build_project_detail_text("vitalis")
        send_message(chat_id, txt, reply_markup=build_project_detail_keyboard("vitalis"))

    # Route: Orchestrator Menu & Direct Message (/orchestrator, /agy, /ask)
    elif cmd in ("/orchestrator", "/agy", "/ask", "оркестратор"):
        if arg:
            send_message(chat_id, f"⏳ <b>Передача сообщения оркестратору Antigravity...</b>")
            res = send_to_orchestrator(arg)
            if res.get("ok"):
                conv_id = res.get("conversation_id", "")
                rebound_note = "\n⚡ <i>(Сессия автоматически перепривязана к активному окну)</i>\n" if res.get("auto_rebound") else ""
                send_message(
                    chat_id,
                    f"✅ <b>API принял команду для оркестратора.</b>\n\n"
                    f"🆔 <b>Сессия:</b> <code>{conv_id}</code>{rebound_note}\n"
                    f"💬 <b>Текст:</b> <i>«{arg}»</i>\n\n"
                    f"• Исполнение не подтверждено.",
                    reply_markup=build_orchestrator_keyboard()
                )
            else:
                send_message(
                    chat_id,
                    f"❌ <b>Ошибка передачи оркестратору:</b>\n\n<code>{res.get('error')}</code>",
                    reply_markup=build_orchestrator_keyboard()
                )
        else:
            txt = build_orchestrator_text()
            send_message(chat_id, txt, reply_markup=build_orchestrator_keyboard())

    # Route: Set Orchestrator Conversation ID
    elif cmd in ("/set_orchestrator", "/set_agy", "/set_orch"):
        if arg:
            val_res = validate_conversation_id(arg)
            if val_res.get("ok"):
                workspaces = val_res.get("workspaces", [])
                set_orchestrator_config(arg, workspaces=workspaces)
                ws_text = "\n".join([f" • <code>{w.split('/')[-1]}</code>" for w in workspaces]) if workspaces else " • <i>(определены)</i>"
                send_message(
                    chat_id,
                    f"✅ <b>Conversation ID оркестратора успешно обновлён!</b>\n\n"
                    f"🆔 <b>Новый ID:</b> <code>{arg}</code>\n"
                    f"📁 <b>Рабочие пространства:</b>\n{ws_text}",
                    reply_markup=build_orchestrator_keyboard()
                )
            else:
                send_message(
                    chat_id,
                    f"❌ <b>Сессия не найдена:</b>\n\n<code>{val_res.get('error')}</code>\n\n"
                    f"Убедитесь, что указан корректный UUID существующей сессии Antigravity.",
                    reply_markup=build_orchestrator_keyboard()
                )
        else:
            set_pending_input(chat_id, "set_orchestrator")
            send_message(
                chat_id,
                f"🆔 <b>Введите новый Conversation ID оркестратора:</b>\n\n"
                f"Отправьте UUID сессии Antigravity следующим сообщением.\n\n"
                f"<i>Для отмены отправьте /cancel</i>",
                reply_markup=build_input_cancel_keyboard()
            )

    # Route: Pause (Global or Specific Project)
    elif cmd in ("/pause", "/mitm", "/mim", "/man_in_the_middle", "пауза", "мим"):
        target = normalize_project_key(arg)
        if target:
            projects = get_all_projects()
            p_name = projects.get(target, {}).get("name", target.upper())
            pause_project(target, f"Пауза {p_name} по команде владельца")
            send_message(
                chat_id,
                f"⏸ <b>Проект {p_name} поставлен на ПАУЗУ</b>\n\n"
                f"• Вкладка ChatGPT {p_name} заморожена (нет авто-перезагрузок, нет auto-nudge).\n"
                f"• Остальные проекты продолжают работу в штатном режиме.\n"
                f"• Для возобновления: <code>/resume {target}</code>",
                reply_markup=build_project_detail_keyboard(target)
            )
        else:
            reason = arg or "Владелец перевёл пайплайн в режим MitM через Telegram"
            pause_pipeline(mode="MAN_IN_THE_MIDDLE", reason=reason)
            msg = (
                f"⏸ <b>Пайплайн поставлен на ПАУЗУ (MitM)</b>\n\n"
                f"• <b>Причина:</b> <i>{reason}</i>\n"
                f"• Авто-перезагрузки страниц и авто-напоминания всех проектов заморожены.\n"
                f"• Вы можете свободно общаться с ChatGPT, оркестратором или редактировать код."
            )
            send_message(chat_id, msg, reply_markup=build_main_keyboard())

    # Route: Resume (Global or Specific Project)
    elif cmd in ("/resume", "/unpause", "пуск", "возобновить", "продолжить"):
        target = normalize_project_key(arg)
        if target:
            projects = get_all_projects()
            p_name = projects.get(target, {}).get("name", target.upper())
            resume_project(target)
            send_message(
                chat_id,
                f"▶️ <b>Проект {p_name} ВОЗОБНОВЛЁН</b>\n\n"
                f"• Вкладка ChatGPT разморожена.\n"
                f"• Цикл вернулся к штатному опросу и исполнению.",
                reply_markup=build_project_detail_keyboard(target)
            )
        else:
            res = resume_pipeline()
            dur_sec = res.get("last_pause_duration_sec", 0)
            dur_str = format_duration(dur_sec)
            msg = (
                f"▶️ <b>Пайплайн СНЯТ С ПАУЗЫ (возобновлён)</b>\n\n"
                f"• <b>Время на паузе:</b> {dur_str}\n"
                f"• Таймеры ожидания откалиброваны, активирован 60-сек льготный период.\n"
                f"• Выполняется поиск сформированных Action Packets и проверка чатов..."
            )
            send_message(chat_id, msg, reply_markup=build_main_keyboard())

    # Route: Legacy per-project pause/resume aliases
    elif cmd in ("/pause_h10", "пауза_h10"):
        pause_project("h10", "Пауза H10 по команде владельца")
        send_message(chat_id, "⏸ <b>Проект H10 Athlete Cardio Lab поставлен на ПАУЗУ</b>", reply_markup=build_project_detail_keyboard("h10"))

    elif cmd in ("/pause_vitalis", "пауза_vitalis"):
        pause_project("vitalis", "Пауза Vitalis по команде владельца")
        send_message(chat_id, "⏸ <b>Проект Vitalis поставлен на ПАУЗУ</b>", reply_markup=build_project_detail_keyboard("vitalis"))

    elif cmd in ("/resume_h10", "/unpause_h10", "пуск_h10"):
        resume_project("h10")
        send_message(chat_id, "▶️ <b>Проект H10 ВОЗОБНОВЛЁН</b>", reply_markup=build_project_detail_keyboard("h10"))

    elif cmd in ("/resume_vitalis", "/unpause_vitalis", "пуск_vitalis"):
        resume_project("vitalis")
        send_message(chat_id, "▶️ <b>Проект Vitalis ВОЗОБНОВЛЁН</b>", reply_markup=build_project_detail_keyboard("vitalis"))

    # Route: Diagnostic Trigger
    elif cmd in ("/diagnose", "/diagnostic", "диагностика"):
        proj = normalize_project_key(arg) if arg else "vitalis"
        send_message(chat_id, f"🔍 <b>Запуск диагностики для проекта {proj}...</b>")
        trigger_script = PIPELINE_ROOT / "scripts" / "bridge" / "trigger_supervisor_diagnostic.py"
        if trigger_script.is_file():
            try:
                sub_res = subprocess.run(
                    [sys.executable, str(trigger_script), "--project-key", proj, "--reason", "MANUAL_TELEGRAM_TRIGGER", "--details", "Запрос владельца из Telegram бота"],
                    capture_output=True, text=True, timeout=25, creationflags=CREATE_NO_WINDOW
                )
                if sub_res.returncode == 0:
                    data = json.loads(sub_res.stdout)
                    send_message(
                        chat_id,
                        f"🤖 <b>Диагностический агент Antigravity успешно запущен!</b>\n\n"
                        f"• <b>Проект:</b> <code>{proj}</code>\n"
                        f"• <b>Сессия Supervisor:</b> <code>{data.get('conversation_id')}</code>\n\n"
                        f"<i>Агент в Antigravity анализирует control plane, состояние транспорта и исполнителя.</i>",
                        reply_markup=build_main_keyboard()
                    )
                else:
                    err = sub_res.stderr.strip() or sub_res.stdout.strip()
                    send_message(chat_id, f"❌ <b>Ошибка вызова диагностики:</b>\n\n<code>{err}</code>")
            except Exception as e:
                send_message(chat_id, f"❌ <b>Ошибка выполнения команды:</b> {e}")
        else:
            send_message(chat_id, f"❌ Скрипт диагностики не найден: <code>{trigger_script}</code>")

    # Route: Directive
    elif cmd in ("/directive", "директива"):
        if not arg:
            d = get_directive()
            if d.get("active") and d.get("text"):
                send_message(
                    chat_id,
                    f"🎯 <b>Текущая активная директива:</b>\n\n«{d['text']}»\n\n"
                    f"<i>Чтобы изменить, напишите:</i> <code>/directive &lt;новый текст&gt;</code>\n"
                    f"<i>Чтобы сбросить, напишите:</i> <code>/directive_clear</code>",
                    reply_markup=build_directive_keyboard()
                )
            else:
                send_message(
                    chat_id,
                    f"ℹ️ <b>Активных директив нет.</b>\n\n"
                    f"Чтобы задать директиву владельца для следующих промптов компаньона, напишите:\n"
                    f"<code>/directive &lt;текст директивы&gt;</code>"
                )
        else:
            set_directive(arg)
            send_message(
                chat_id,
                f"✅ <b>Директива владельца успешно сохранена!</b>\n\n"
                f"🎯 <b>Текст:</b> «{arg}»\n\n"
                f"<i>Она будет автоматически прикреплена к каждому следующему промпту контекста или напоминанию компаньону.</i>",
                reply_markup=build_main_keyboard()
            )

    elif cmd in ("/directive_clear", "/nodirective", "сброс_директивы"):
        clear_directive()
        send_message(
            chat_id,
            f"✅ <b>Директива владельца сброшена.</b> Промпты будут отправляться в стандартном режиме.",
            reply_markup=build_main_keyboard()
        )

    # Route: Restart
    elif cmd in ("/restart", "рестарт"):
        send_message(chat_id, "🔄 <b>Выполняется проверка и перезапуск служб через супервизор...</b>")
        r = execute_supervisor_ensure()
        st_text = "Все службы активны." if r["success"] else f"Внимание: {r['output']}"
        time.sleep(1.0)
        services = get_services_status()
        send_message(
            chat_id,
            f"✅ <b>Проверка служб завершена</b>\n\n"
            f"• Companion Bridge: <code>PID {services['companion_bridge']}</code>\n"
            f"• Action Bridge: <code>PID {services['action_bridge']}</code>\n"
            f"• Process Guard: <code>PID {services['process_guard']}</code>\n"
            f"• Telegram Bot: <code>PID {os.getpid()}</code>\n\n"
            f"<i>{st_text}</i>",
            reply_markup=build_main_keyboard()
        )

    # Route: Reply to companion
    elif cmd in ("/reply", "ответить", "ответ"):
        # Check if first word of arg is a project key
        sub_parts = arg.split(maxsplit=1) if arg else []
        specified_proj = normalize_project_key(sub_parts[0]) if sub_parts else None
        reply_body = sub_parts[1].strip() if (specified_proj and len(sub_parts) > 1) else (arg if not specified_proj else "")

        waiting_proj = specified_proj or get_waiting_owner_gate_project()
        if reply_body:
            if waiting_proj:
                projects = get_all_projects()
                proj_label = projects.get(waiting_proj, {}).get("name", waiting_proj.upper())
                send_message(chat_id, f"⏳ <b>Отправка ответа в ChatGPT ({proj_label})...</b>")
                res = send_to_companion(waiting_proj, reply_body)
                if res.get("ok"):
                    send_message(
                        chat_id,
                        f"✅ <b>Ответ успешно отправлен в чат {proj_label}!</b>\n\n"
                        f"• Текст передан напрямую в форму ввода ChatGPT.\n"
                        f"• Флаг ожидания решения снят, компаньон продолжает работу.",
                        reply_markup=build_project_detail_keyboard(waiting_proj)
                    )
                else:
                    send_message(chat_id, f"❌ <b>Ошибка отправки в {proj_label}:</b>\n<code>{res.get('error')}</code>", reply_markup=build_main_keyboard())
            else:
                save_cached_text(chat_id, reply_body)
                # Show dynamic project choices
                projects = get_all_projects()
                buttons = []
                for k, p in projects.items():
                    buttons.append([{"text": f"{p.get('icon', '📁')} В чат {p.get('name', k)}", "callback_data": f"cb_confirm_send_{k}"}])
                buttons.append([{"text": "🤖 Оркестратору Antigravity", "callback_data": "cb_confirm_send_orchestrator"}])
                buttons.append([{"text": "❌ Отмена", "callback_data": "cb_reply_cancel"}])
                send_message(
                    chat_id,
                    f"💬 <b>Куда отправить ответ?</b>\n\n«<i>{reply_body}</i>»",
                    reply_markup={"inline_keyboard": buttons}
                )
        else:
            if waiting_proj:
                set_pending_input(chat_id, "companion_reply", waiting_proj)
                projects = get_all_projects()
                proj_label = projects.get(waiting_proj, {}).get("name", waiting_proj.upper())
                send_message(
                    chat_id,
                    f"💬 <b>Введите текст ответа для {proj_label}:</b>\n\n"
                    f"Отправьте сообщение следующим текстом в этот диалог. Оно будет передано напрямую в ChatGPT.\n\n"
                    f"<i>Для отмены нажмите кнопку ниже или отправьте /cancel</i>",
                    reply_markup=build_input_cancel_keyboard()
                )
            else:
                projects = get_all_projects()
                buttons = []
                for k, p in projects.items():
                    buttons.append([{"text": f"{p.get('icon', '📁')} Для {p.get('name', k)}", "callback_data": f"cb_reply_prompt_{k}"}])
                buttons.append([{"text": "🤖 Для оркестратора AGY", "callback_data": "cb_orch_send_prompt"}])
                buttons.append([{"text": "❌ Отмена", "callback_data": "cb_reply_cancel"}])
                send_message(
                    chat_id,
                    f"💬 <b>Выберите адресата для ввода сообщения:</b>",
                    reply_markup={"inline_keyboard": buttons}
                )

    # Route: Legacy reply shortcuts
    elif cmd in ("/reply_vitalis", "/reply_vit"):
        if arg:
            send_message(chat_id, "⏳ <b>Отправка ответа в ChatGPT (Vitalis)...</b>")
            res = send_to_companion("vitalis", arg)
            if res.get("ok"):
                send_message(chat_id, "✅ <b>Ответ успешно отправлен в чат Vitalis!</b>", reply_markup=build_project_detail_keyboard("vitalis"))
            else:
                send_message(chat_id, f"❌ <b>Ошибка:</b> <code>{res.get('error')}</code>")
        else:
            set_pending_input(chat_id, "companion_reply", "vitalis")
            send_message(chat_id, "💬 <b>Введите текст ответа для Vitalis:</b>", reply_markup=build_input_cancel_keyboard())

    elif cmd in ("/reply_h10",):
        if arg:
            send_message(chat_id, "⏳ <b>Отправка ответа в ChatGPT (H10 Athlete)...</b>")
            res = send_to_companion("h10", arg)
            if res.get("ok"):
                send_message(chat_id, "✅ <b>Ответ успешно отправлен в чат H10 Athlete!</b>", reply_markup=build_project_detail_keyboard("h10"))
            else:
                send_message(chat_id, f"❌ <b>Ошибка:</b> <code>{res.get('error')}</code>")
        else:
            set_pending_input(chat_id, "companion_reply", "h10")
            send_message(chat_id, "💬 <b>Введите текст ответа для H10 Athlete:</b>", reply_markup=build_input_cancel_keyboard())

    # Route: Sleep
    elif cmd in ("/sleep", "сон"):
        send_message(
            chat_id,
            f"🌙 <b>Безопасный спящий режим ПК</b>\n\n"
            f"⚠️ <b>Подтвердите действие:</b>\n"
            f"1. Пайплайн будет чисто переведён в режим паузы <code>PRE_SLEEP</code>.\n"
            f"2. Windows получит сигнал перехода в спящий режим (Suspend).\n"
            f"3. При включении ПК пайплайн можно будет возобновить командой <code>/resume</code>.",
            reply_markup=build_sleep_confirm_keyboard()
        )

    # Route: Ping
    elif cmd in ("/ping", "пинг"):
        now_ts = dt.datetime.now().strftime("%H:%M:%S")
        send_message(chat_id, f"🏓 <b>Pong!</b> Бот активен и готов к командам ({now_ts}).")

    # Route: Smart text routing for unprompted messages
    else:
        waiting_proj = get_waiting_owner_gate_project()
        save_cached_text(chat_id, raw)
        if waiting_proj:
            projects = get_all_projects()
            proj_label = projects.get(waiting_proj, {}).get("name", waiting_proj.upper())
            buttons = [
                [{"text": f"✅ Отправить ответ в {proj_label}", "callback_data": f"cb_confirm_send_{waiting_proj}"}],
                [{"text": "🤖 Отправить оркестратору Antigravity", "callback_data": "cb_confirm_send_orchestrator"}],
                [{"text": "❌ Отмена", "callback_data": "cb_reply_cancel"}]
            ]
            send_message(
                chat_id,
                f"💬 <b>Проект {proj_label} ожидает решения владельца!</b>\n\n"
                f"Куда направить ваше сообщение?\n\n"
                f"«<i>{raw}</i>»",
                reply_markup={"inline_keyboard": buttons}
            )
        else:
            projects = get_all_projects()
            buttons = [
                [{"text": "🤖 Оркестратору Antigravity", "callback_data": "cb_confirm_send_orchestrator"}]
            ]
            for k, p in projects.items():
                icon = p.get("icon", "📁")
                name = p.get("name", k)
                buttons.append([{"text": f"{icon} В чат {name}", "callback_data": f"cb_confirm_send_{k}"}])
            buttons.append([{"text": "❌ Отмена", "callback_data": "cb_reply_cancel"}])

            send_message(
                chat_id,
                f"💬 <b>Куда направить это сообщение?</b>\n\n"
                f"«<i>{raw}</i>»",
                reply_markup={"inline_keyboard": buttons}
            )


# =========================================================================
# Callback Query Dispatcher
# =========================================================================

def handle_callback(cb: dict) -> None:
    cb_id = str(cb.get("id", ""))
    data = str(cb.get("data", ""))
    msg = cb.get("message", {})
    chat_id = str(msg.get("chat", {}).get("id", ""))
    msg_id = msg.get("message_id")

    if data in ("cb_status", "cb_refresh"):
        answer_callback(cb_id, "Дашборд обновлён 🔄")
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_projects_list":
        answer_callback(cb_id)
        txt = build_projects_menu_text()
        edit_message(chat_id, msg_id, txt, reply_markup=build_projects_menu_keyboard())

    elif data.startswith("cb_proj_card_"):
        proj_key = data.replace("cb_proj_card_", "")
        answer_callback(cb_id)
        txt = build_project_detail_text(proj_key)
        edit_message(chat_id, msg_id, txt, reply_markup=build_project_detail_keyboard(proj_key))

    elif data.startswith("cb_proj_pause_"):
        proj_key = data.replace("cb_proj_pause_", "")
        pause_project(proj_key, f"Пауза {proj_key} по кнопке в Telegram")
        answer_callback(cb_id, f"⏸ Проект {proj_key} поставлен на паузу")
        txt = build_project_detail_text(proj_key)
        edit_message(chat_id, msg_id, txt, reply_markup=build_project_detail_keyboard(proj_key))

    elif data.startswith("cb_proj_resume_"):
        expected_epoch = None
        if ":e:" in data:
            action, separator, raw_epoch = data.rpartition(":e:")
            if separator and raw_epoch.isdigit():
                expected_epoch = int(raw_epoch)
                proj_key = action.replace("cb_proj_resume_", "", 1)
            else:
                answer_callback(cb_id, "Кнопка устарела. Обновите панель.", show_alert=True)
                return
        else:
            proj_key = data.replace("cb_proj_resume_", "", 1)
        try:
            resume_project(proj_key, expected_epoch=expected_epoch)
            answer_callback(cb_id, f"▶️ Проект {proj_key} возобновлён!")
        except Exception as e:
            answer_callback(cb_id, f"Ошибка: {e}", show_alert=True)
            return
        txt = build_project_detail_text(proj_key)
        edit_message(chat_id, msg_id, txt, reply_markup=build_project_detail_keyboard(proj_key))

    elif data.startswith("cb_proj_refresh_"):
        proj_key = data.replace("cb_proj_refresh_", "")
        answer_callback(cb_id, "Данные обновлены 🔄")
        txt = build_project_detail_text(proj_key)
        edit_message(chat_id, msg_id, txt, reply_markup=build_project_detail_keyboard(proj_key))

    elif data == "cb_orchestrator_menu" or data == "cb_orch_refresh":
        answer_callback(cb_id, "Статус оркестратора обновлён 🤖")
        txt, kb = build_orchestrator_view(force_refresh=True)
        edit_message(chat_id, msg_id, txt, reply_markup=kb)

    elif data.startswith("cb_orch_bind_"):
        new_id = data.replace("cb_orch_bind_", "").strip()
        val = validate_conversation_id(new_id, check_discovery=False)
        if val.get("ok"):
            set_orchestrator_config(new_id, workspaces=val.get("workspaces"))
            answer_callback(cb_id, "Сессия успешно привязана! ⚡", show_alert=True)
            txt, kb = build_orchestrator_view(force_refresh=True)
            edit_message(chat_id, msg_id, txt, reply_markup=kb)
        else:
            answer_callback(cb_id, f"Ошибка привязки: {val.get('error')}", show_alert=True)

    elif data == "cb_orch_send_prompt":
        cfg = get_orchestrator_config()
        conv_id = cfg.get("conversation_id", DEFAULT_ORCHESTRATOR_ID)
        set_pending_input(chat_id, "orchestrator", conv_id)
        answer_callback(cb_id)
        send_message(
            chat_id,
            f"🤖 <b>Введите сообщение для оркестратора Antigravity:</b>\n\n"
            f"🆔 <b>Целевая сессия:</b> <code>{conv_id}</code>\n\n"
            f"Отправьте ваш запрос следующим сообщением. Оно реактивно пробудит агента и передастся в контекст задачи.\n\n"
            f"<i>Для отмены отправьте /cancel или нажмите кнопку ниже</i>",
            reply_markup=build_input_cancel_keyboard()
        )

    elif data == "cb_orch_set_id_prompt":
        set_pending_input(chat_id, "set_orchestrator")
        answer_callback(cb_id)
        send_message(
            chat_id,
            f"🆔 <b>Введите новый Conversation ID оркестратора:</b>\n\n"
            f"Отправьте UUID сессии Antigravity следующим сообщением.\n\n"
            f"<i>Для отмены отправьте /cancel</i>",
            reply_markup=build_input_cancel_keyboard()
        )

    elif data == "cb_confirm_send_orchestrator":
        txt = get_cached_text(chat_id)
        if not txt:
            answer_callback(cb_id, "Текст сообщения устарел или не найден", show_alert=True)
            dash = build_dashboard_text()
            edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())
            return
        answer_callback(cb_id, "Передача оркестратору... 🤖")
        edit_message(chat_id, msg_id, "⏳ <b>Передача сообщения оркестратору Antigravity...</b>")
        clear_cached_text()
        clear_pending_input()
        res = send_to_orchestrator(txt)
        if res.get("ok"):
            conv_id = res.get("conversation_id", "")
            rebound_note = "\n⚡ <i>(Сессия автоматически перепривязана к активному окну)</i>\n" if res.get("auto_rebound") else ""
            edit_message(
                chat_id,
                msg_id,
                f"✅ <b>API принял команду для оркестратора.</b>\n\n"
                f"🆔 <b>Сессия:</b> <code>{conv_id}</code>{rebound_note}\n"
                f"💬 <b>Текст:</b> <i>«{txt}»</i>\n\n"
                f"• Исполнение не подтверждено.",
                reply_markup=build_orchestrator_keyboard()
            )
        else:
            edit_message(
                chat_id,
                msg_id,
                f"❌ <b>Ошибка передачи оркестратору:</b>\n\n<code>{res.get('error')}</code>",
                reply_markup=build_orchestrator_keyboard()
            )

    elif data.startswith("cb_confirm_send_"):
        proj_key = data.replace("cb_confirm_send_", "")
        txt = get_cached_text(chat_id)
        if not txt:
            answer_callback(cb_id, "Текст сообщения устарел или не найден", show_alert=True)
            dash = build_dashboard_text()
            edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())
            return
        projects = get_all_projects()
        proj_label = projects.get(proj_key, {}).get("name", proj_key.upper())
        answer_callback(cb_id, f"Отправка в {proj_label}... ⏳")
        edit_message(chat_id, msg_id, f"⏳ <b>Отправка сообщения в ChatGPT ({proj_label})...</b>")
        clear_cached_text()
        clear_pending_input()
        res = send_to_companion(proj_key, txt)
        if res.get("ok"):
            edit_message(
                chat_id,
                msg_id,
                f"✅ <b>Ответ успешно передан в чат {proj_label}!</b>\n\n"
                f"• Текст передан напрямую в форму ввода ChatGPT.\n"
                f"• Флаг ожидания решения снят, компаньон продолжает работу.",
                reply_markup=build_project_detail_keyboard(proj_key)
            )
        else:
            edit_message(
                chat_id,
                msg_id,
                f"❌ <b>Ошибка отправки в {proj_label}:</b>\n<code>{res.get('error')}</code>",
                reply_markup=build_project_detail_keyboard(proj_key)
            )

    elif data.startswith("cb_reply_prompt_"):
        proj_key = data.replace("cb_reply_prompt_", "")
        set_pending_input(chat_id, "companion_reply", proj_key)
        projects = get_all_projects()
        proj_label = projects.get(proj_key, {}).get("name", proj_key.upper())
        answer_callback(cb_id)
        send_message(
            chat_id,
            f"💬 <b>Введите текст ответа для {proj_label}:</b>\n\n"
            f"Отправьте сообщение следующим текстом в этот диалог. Оно будет передано напрямую в ChatGPT.\n\n"
            f"<i>Для отмены нажмите кнопку ниже или отправьте /cancel</i>",
            reply_markup=build_input_cancel_keyboard()
        )

    elif data == "cb_reply_cancel":
        clear_pending_input()
        clear_cached_text()
        answer_callback(cb_id, "Ввод отменён")
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_pause":
        pause_pipeline(mode="MAN_IN_THE_MIDDLE", reason="Кнопка паузы в Telegram")
        # Kill supervisor_watch so it stops restarting daemons during pause.
        try:
            import psutil as _psutil
            my_pid = os.getpid()
            for _p in _psutil.process_iter(['pid', 'name', 'cmdline']):
                try:
                    if _p.info['pid'] == my_pid:
                        continue
                    _cmd = " ".join(_p.info.get('cmdline') or []).lower()
                    if "daemon_supervisor.py" in _cmd and ("--watch" in _cmd or " watch" in _cmd):
                        _p.kill()
                        log_event(f"[PAUSE] Killed supervisor_watch PID {_p.info['pid']}")
                except Exception:
                    pass
        except Exception as _e:
            log_event(f"[PAUSE] Could not kill supervisor_watch: {_e}")
        answer_callback(cb_id, "⏸ Пайплайн поставлен на паузу (MitM). Supervisor остановлен.")
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_resume" or data.startswith("cb_resume:e:"):
        expected_epoch = None
        if ":e:" in data:
            action, separator, raw_epoch = data.rpartition(":e:")
            if separator and raw_epoch.isdigit():
                expected_epoch = int(raw_epoch)
            else:
                answer_callback(cb_id, "Кнопка устарела. Обновите панель.", show_alert=True)
                return
        try:
            resume_pipeline(expected_epoch=expected_epoch)
            answer_callback(cb_id, "▶️ Пайплайн возобновлён!")
        except Exception as e:
            answer_callback(cb_id, f"Ошибка возобновления: {e}", show_alert=True)
            return
        # Re-launch supervisor_watch so it brings companion_bridge and guard back.
        try:
            import daemon_supervisor as _ds
            w_pid = _ds.is_watch_running()
            if not w_pid:
                w_pid = _ds.ensure_watch_daemon()
                log_event(f"[RESUME] supervisor_watch launched (PID {w_pid})")
            else:
                log_event(f"[RESUME] supervisor_watch already running (PID {w_pid})")
        except Exception as _e:
            log_event(f"[RESUME] Could not start supervisor_watch: {_e}")
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_directive_view":
        d = get_directive()
        if d.get("active") and d.get("text"):
            answer_callback(cb_id)
            edit_message(
                chat_id,
                msg_id,
                f"🎯 <b>Текущая активная директива:</b>\n\n«{d['text']}»\n\n"
                f"<i>Чтобы изменить директиву, напишите в чат:</i>\n"
                f"<code>/directive &lt;текст директивы&gt;</code>",
                reply_markup=build_directive_keyboard()
            )
        else:
            answer_callback(cb_id, "Активных директив нет")
            edit_message(
                chat_id,
                msg_id,
                f"ℹ️ <b>Активных директив нет.</b>\n\n"
                f"Чтобы задать директиву владельца для компаньона, отправьте команду:\n"
                f"<code>/directive &lt;текст директивы&gt;</code>",
                reply_markup=build_directive_keyboard()
            )

    elif data == "cb_directive_clear":
        clear_directive()
        answer_callback(cb_id, "Директива сброшена ✅")
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_chatgpt_limit":
        answer_callback(cb_id, "Проверка лимита... ⏳")
        import chatgpt_usage_monitor as um
        state = um.load_saved_state()
        live = um.extract_live_usage()
        if live and live.get("percent") is not None:
            pct = live["percent"]
            rem_txt = live.get("remainingText") or f"Остается {pct}%"
            res_txt = live.get("resetText") or "—"
            avail = live.get("resetsAvailable") if live.get("resetsAvailable") is not None else "—"
            now_str = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            state["percent"] = pct
            state["remainingText"] = rem_txt
            state["resetText"] = res_txt
            state["resetsAvailable"] = avail
            state["lastCheckedAt"] = now_str
            um.save_state(state)
            icon = "🟢" if pct > 0 else "🔴"
            msg = (
                f"⚡ <b>ТЕКУЩИЙ ЛИМИТ CHATGPT</b>\n\n"
                f"{icon} <b>Недельный лимит:</b> <code>{pct}%</code> ({rem_txt})\n"
                f"🔄 <b>Доступно сбросов:</b> <code>{avail}</code>\n"
                f"⏳ <b>Сброс через:</b> <code>{res_txt}</code>\n"
                f"🕒 <b>Обновлено:</b> {now_str}\n\n"
                f"💡 <i>Отслеживание активно: бот пришлёт push при сбросе лимита.</i>"
            )
        else:
            pct = state.get("percent", 0)
            rem_txt = state.get("remainingText", "Остается 0%")
            last_chk = state.get("lastCheckedAt", "—")
            msg = (
                f"⚡ <b>СОХРАНЁННЫЙ ЛИМИТ CHATGPT</b>\n\n"
                f"🔴 <b>Последнее значение:</b> <code>{pct}%</code> ({rem_txt})\n"
                f"🕒 <b>Проверено в:</b> {last_chk}\n"
                f"⚠️ <i>Браузер закрыт или вкладка недоступна в CDP. При открытии браузера значение обновится автоматически.</i>"
            )
        edit_message(chat_id, msg_id, msg, reply_markup=build_main_keyboard())

    elif data == "cb_restart":
        answer_callback(cb_id, "Проверка служб... 🔄")
        execute_supervisor_ensure()
        time.sleep(1.0)
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_sleep_prompt":
        answer_callback(cb_id)
        edit_message(
            chat_id,
            msg_id,
            f"🌙 <b>Безопасный спящий режим ПК</b>\n\n"
            f"⚠️ Подтвердите отправку ПК в сон.\n"
            f"Пайплайн будет чисто поставлен на паузу, затем Windows заснёт.",
            reply_markup=build_sleep_confirm_keyboard()
        )

    elif data == "cb_sleep_cancel":
        answer_callback(cb_id, "Отменено")
        dash = build_dashboard_text()
        edit_message(chat_id, msg_id, dash, reply_markup=build_main_keyboard())

    elif data == "cb_sleep_confirm":
        answer_callback(cb_id, "ПК переходит в спящий режим... 🌙", show_alert=True)
        edit_message(
            chat_id,
            msg_id,
            f"💤 <b>ПК переводится в спящий режим...</b>\n\n"
            f"Пайплайн поставлен на паузу. После пробуждения отправьте <code>/resume</code>."
        )
        execute_safe_sleep()

    elif data == "cb_help":
        answer_callback(cb_id)
        ref = get_command_reference_text()
        edit_message(chat_id, msg_id, ref, reply_markup=build_main_keyboard())

    else:
        answer_callback(cb_id, "Неизвестное действие")


# =========================================================================
# Bot Commands Registration (setMyCommands API)
# =========================================================================

def register_bot_commands() -> bool:
    commands = [
        {"command": "status", "description": "📊 Дашборд и сводный статус системы"},
        {"command": "limit", "description": "⚡ Недельный лимит ChatGPT и сбросы"},
        {"command": "projects", "description": "📁 Каталог и управление проектами"},
        {"command": "orchestrator", "description": "🤖 Написать оркестратору Antigravity"},
        {"command": "set_orchestrator", "description": "🆔 Сменить Conversation ID оркестратора"},
        {"command": "reply", "description": "💬 Ответить компаньону ChatGPT"},
        {"command": "pause", "description": "⏸ Пауза системы или проекта (/pause <проект>)"},
        {"command": "resume", "description": "▶️ Возобновление системы или проекта"},
        {"command": "directive", "description": "🎯 Задать директиву владельца"},
        {"command": "directive_clear", "description": "❌ Сбросить директиву владельца"},
        {"command": "restart", "description": "🔄 Самоисцеление и рестарт служб"},
        {"command": "sleep", "description": "🌙 Безопасный перевод ПК в сон"},
        {"command": "help", "description": "📖 Полное руководство по командам"}
    ]
    res = api_request("setMyCommands", {"commands": commands})
    ok = bool(res.get("ok"))
    log_event(f"Registered Telegram bot commands: {ok}")
    return ok


# =========================================================================
# Background ChatGPT Usage Limit Monitor
# =========================================================================

def _start_usage_monitor_thread() -> None:
    """Runs a 24/7 background monitor for ChatGPT weekly limit recovery and manual resets."""
    import threading
    def _loop():
        log_event("[USAGE_MONITOR] Background limit monitor thread started (interval: 60 minutes)")
        time.sleep(10.0) # initial warm-up
        while True:
            sleep_sec = 3600 # Check every 60 minutes per user configuration
            try:
                import chatgpt_usage_monitor as um
                token, chat_id = get_telegram_creds()
                if token and chat_id:
                    res = um.check_and_notify_if_needed(send_message, chat_id)
                    if res.get("status") == "alert_triggered":
                        log_event(f"[USAGE_MONITOR] ALERT: {res.get('reason')} triggered! (Pct: {res.get('previous_percent')}% -> {res.get('current_percent')}%, Resets: {res.get('previous_resets')} -> {res.get('current_resets')})")
            except Exception as e:
                log_event(f"[USAGE_MONITOR_ERROR] {e}")
            time.sleep(sleep_sec)

    t = threading.Thread(target=_loop, daemon=True, name="ChatGPTUsageMonitor")
    t.start()


# =========================================================================
# Main Polling Loop
# =========================================================================

def run_polling():
    _start_usage_monitor_thread()
    from telegram_bot_integration import run_polling as durable_run_polling
    return durable_run_polling(globals())


if __name__ == "__main__":
    run_polling()
