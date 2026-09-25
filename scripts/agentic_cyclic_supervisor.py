#!/usr/bin/env python3
"""
Agentic Cyclic System Supervisor
Ensures all continuous services of the Agentic Pipeline cyclic system are running:
1. ChatGPT Companion Bridge (companion_bridge.js watch)
2. Action Bridge (companion_action_bridge.py watch)

Features:
- Zero window/console creation (100% silent, zero screen flickering)
- Detached independent processes that survive Antigravity IDE restarts
- Self-healing recovery within seconds if any service stops
"""
from runtime_paths import runtime_path

import argparse
import datetime as dt
import json
import os
from pipeline_runtime_state import snapshot as runtime_snapshot, dispatch_recovery as runtime_dispatch, dispatch_runtime_effect
from process_identity import fingerprint, health, command_matches
from types import SimpleNamespace
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

LOG_DIR = Path(runtime_path("AGENTIC_STATE_ROOT","logs"))
SUPERVISOR_LOG = LOG_DIR / "supervisor.log"

NODE_EXE = Path(runtime_path("AGENTIC_NODE",""))
PYTHON_EXE = Path(runtime_path("AGENTIC_PYTHON",""))
PYTHONW_EXE = Path(runtime_path("AGENTIC_PYTHONW",""))

COMPANION_BRIDGE_JS = Path(runtime_path("AGENTIC_RUNTIME_SCRIPTS_DIR","companion_bridge.js"))
ACTION_BRIDGE_PY = Path(runtime_path("AGENTIC_ACTION_BRIDGE_SCRIPT",""))
PROCESS_GUARD_PY = Path(runtime_path("AGENTIC_RUNTIME_SCRIPTS_DIR","antigravity_process_guard.py"))
TELEGRAM_BOT_PY = Path(runtime_path("AGENTIC_RUNTIME_SCRIPTS_DIR","telegram_cycle_bot.py"))
ANTIGRAVITY_EXE = Path(runtime_path("ANTIGRAVITY_INSTALL_ROOT","Antigravity.exe"))

INBOX_DIR = Path(runtime_path("AGENTIC_DOWNLOADS_DIR",""))
REGISTRY_JSON = Path(runtime_path("AGENTIC_PROJECT_REGISTRY",""))
STATE_ROOT = Path(runtime_path("AGENTIC_STATE_ROOT",""))
STANDBY_STATE_PATH = STATE_ROOT / "STANDBY_STATE.json"
CONFIG_PATH = Path(runtime_path("ANTIGRAVITY_DATA_ROOT","companion_bridge_config.json"))
QUOTA_RECOVERY_LOCK = Path(runtime_path("AGENTIC_HANDOFF_ROOT","state/quota_recovery.lock"))

CREATE_NO_WINDOW = 0x08000000
DETACHED_PROCESS = 0x00000008


import ctypes

SUPERVISOR_PIDS_FILE = STATE_ROOT / "supervisor_pids.json"


def is_antigravity_running() -> bool:
    """Checks whether any Antigravity.exe process is alive."""
    try:
        import psutil
        for p in psutil.process_iter(['name']):
            try:
                if (p.info['name'] or '').lower() == 'antigravity.exe':
                    return True
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except Exception:
        pass
    return False


def _start_antigravity_unfenced() -> bool:
    """Safely launches Antigravity on the user's interactive desktop with visible GUI and active workspaces."""
    if not ANTIGRAVITY_EXE.is_file():
        log_event(f"Cannot start Antigravity: executable not found at {ANTIGRAVITY_EXE}")
        return False
    log_event("Starting Antigravity (Antigravity.exe) with visible GUI...")

    # 1. Primary: Use dedicated antigravity_gui_launcher with active project workspaces
    try:
        from antigravity_gui_launcher import launch_antigravity_visible, get_active_workspace_paths, reset_background_and_lock_flags
        reset_background_and_lock_flags()
        workspaces = get_active_workspace_paths()
        if launch_antigravity_visible(workspace_paths=workspaces):
            log_event("Antigravity launch succeeded via antigravity_gui_launcher.")
            return True
    except Exception as e_gl:
        log_event(f"antigravity_gui_launcher failed ({e_gl}), trying fallback...")

    launcher_ps1 = r"C:\Scripts\AntigravityProjects\companion-handoff\src\Launch-AntigravityVisible.ps1"
    desktop_shortcut = os.path.expandvars(r"%USERPROFILE%\Desktop\Antigravity.lnk")

    if os.path.exists(launcher_ps1):
        try:
            cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", launcher_ps1]
            try:
                from antigravity_gui_launcher import get_active_workspace_paths
                ws = get_active_workspace_paths()
                if ws:
                    cmd.extend(["-WorkspacePaths", ",".join(ws)])
            except Exception:
                pass
            res = subprocess.run(cmd, capture_output=True, timeout=45)
            if res.returncode == 0:
                log_event("Antigravity launch initiated via Launch-AntigravityVisible.ps1.")
                return True
        except Exception:
            pass

    if os.path.exists(desktop_shortcut):
        try:
            os.startfile(desktop_shortcut)
            log_event("Antigravity launch initiated via Desktop shortcut.")
            return True
        except Exception:
            pass

    try:
        os.startfile(str(ANTIGRAVITY_EXE))
        log_event("Antigravity launch initiated via os.startfile.")
        return True
    except Exception as e:
        log_event(f"os.startfile failed ({e}), trying PowerShell Start-Process...")
        try:
            cmd_str = (
                f"Start-Process -FilePath '{ANTIGRAVITY_EXE}' "
                "-ArgumentList @('--disable-features=UseEcoQoSForBackgroundProcess', '--disable-renderer-backgrounding', '--disable-background-timer-throttling', '--disable-backgrounding-occluded-windows') "
                "-WindowStyle Normal"
            )
            res = subprocess.run(["powershell", "-NoProfile", "-Command", cmd_str], capture_output=True, timeout=10)
            if res.returncode == 0:
                log_event("Antigravity launch initiated via PowerShell Start-Process (visible).")
                return True
        except Exception as e2:
            log_event(f"Failed to start Antigravity via PowerShell: {e2}")
            return False


def start_antigravity() -> bool:
    return _dispatch_service_start("ide", _start_antigravity_unfenced)

def _dispatch_service_start(service, effect):
    state=runtime_snapshot()
    if state.get("is_standby", True) and service != 'start_telegram_bot':return False
    if DELEGATED_EXPECTED_EPOCH is not None and state.get("epoch") != DELEGATED_EXPECTED_EPOCH:return False
    try:
        import psutil  # Missing process inspection cannot authorize a duplicate start.
        previous=load_supervisor_pids().get(service.removeprefix("start_"))
        previous_hash=__import__("hashlib").sha256(json.dumps(previous,sort_keys=True).encode()).hexdigest()[:24]
        operation=(DELEGATED_OPERATION_ID or "start")+":"+service+":"+previous_hash+":"+str(state.get("runtime_instance"))+":"+str(state["epoch"])
        result=dispatch_runtime_effect(lambda: SimpleNamespace(returncode=0 if effect() else 1),service,operation,expected_epoch=state["epoch"])
        return result.returncode==0
    except Exception as error:
        log_event("[SERVICE_HOLD] "+service+":"+str(error)[:160])
        return False

def start_companion_bridge() -> bool:
    return _dispatch_service_start('start_companion_bridge', _unfenced_start_companion_bridge)

def start_action_bridge() -> bool:
    log_event('[IMPORT_HOLD] Raw automatic Downloads watcher is retired; use verified transport ingress')
    return False

def start_process_guard() -> bool:
    return _dispatch_service_start('start_process_guard', _unfenced_start_process_guard)

def start_telegram_bot() -> bool:
    return _dispatch_service_start('start_telegram_bot', _unfenced_start_telegram_bot)

DELEGATED_EXPECTED_EPOCH = None
DELEGATED_OPERATION_ID = None


def service_reports():
    from native_health import service_reports as collect_native_health, read_object
    try:companions=read_object(CONFIG_PATH).get('browser',{}).get('companions',{})
    except Exception:companions={}
    return collect_native_health(state=runtime_snapshot(),scripts=COMPANION_BRIDGE_JS.parent,state_root=STATE_ROOT,ide_exe=ANTIGRAVITY_EXE,ls_exe=ANTIGRAVITY_EXE.parent/'resources/bin/language_server.exe',companions=companions)


def ensure_report(expected_epoch=None,operation_id=None):
    global DELEGATED_EXPECTED_EPOCH, DELEGATED_OPERATION_ID
    entry=runtime_snapshot()
    result={'schema_version':1,'operation_id':operation_id,'epoch':entry.get('epoch'),'success':False,'required_services':['companion_bridge','process_guard','telegram_bot','ide']}
    if expected_epoch is not None and (type(expected_epoch) is not int or entry.get('epoch')!=expected_epoch):
        result.update(reason='STALE_EPOCH',services=service_reports());return result
    previous=(DELEGATED_EXPECTED_EPOCH,DELEGATED_OPERATION_ID)
    DELEGATED_EXPECTED_EPOCH,DELEGATED_OPERATION_ID=expected_epoch,operation_id
    try:
        ensure_all_services()
        reports=service_reports();current=runtime_snapshot()
        result.update(services=reports,epoch=current.get('epoch'))
        result['success']=current.get('epoch')==entry.get('epoch') and all(r.get('identity_verified') is True and r.get('alive') is True and r.get('healthy') is True for name,r in reports.items() if name in result['required_services'])
        if not result['success']:result['reason']='SERVICE_HEALTH_UNVERIFIED'
        return result
    finally:
        DELEGATED_EXPECTED_EPOCH,DELEGATED_OPERATION_ID=previous

def is_user_manual_pause() -> bool:
    snap = runtime_snapshot()
    if not snap.get("is_standby"):
        return False
    mode = snap.get("mode", "")
    return mode in ("MAN_IN_THE_MIDDLE", "PRE_SLEEP", "PRE_HIBERNATE", "MANUAL", "USER_PAUSE")


def is_quota_rotation_active() -> bool:
    if QUOTA_RECOVERY_LOCK.is_file():
        try:
            age = time.time() - QUOTA_RECOVERY_LOCK.stat().st_mtime
            if age < 60.0:
                return True
        except Exception:
            pass
    return False


def send_telegram_alert(html_message: str):
    try:
        if not CONFIG_PATH.is_file():
            return
        cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        tg = cfg.get("telegram", {})
        if not tg.get("enabled") or not tg.get("botToken") or not tg.get("chatId"):
            return
        token = tg["botToken"]
        chat_id = tg["chatId"]
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        payload = json.dumps({
            "chat_id": chat_id,
            "text": html_message,
            "parse_mode": "HTML"
        }).encode("utf-8")
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            pass
    except Exception:
        pass


def is_pid_alive(pid: int | None) -> bool:
    if not pid or pid <= 0:
        return False
    handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    exit_code = ctypes.c_ulong()
    ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
    ctypes.windll.kernel32.CloseHandle(handle)
    return exit_code.value == 259


def load_supervisor_pids() -> dict[str, int]:
    if SUPERVISOR_PIDS_FILE.is_file():
        try:
            return json.loads(SUPERVISOR_PIDS_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_supervisor_pid(service_name: str, pid: int | None) -> None:
    try:
        import psutil
        pids = load_supervisor_pids()
        if pid: pids[service_name] = fingerprint(psutil.Process(pid))
        else: pids.pop(service_name, None)
        SUPERVISOR_PIDS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = SUPERVISOR_PIDS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(pids, indent=2), encoding="utf-8")
        tmp.replace(SUPERVISOR_PIDS_FILE)
    except Exception as error:
        log_event("[IDENTITY_UNKNOWN] " + type(error).__name__)


def log_event(message: str) -> None:
    now_str = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    line = f"[{now_str}] {message}\n"
    print(line, end="")
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with SUPERVISOR_LOG.open("a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


PROCESS_GUARD_HEARTBEAT = STATE_ROOT / "PROCESS_GUARD_HEARTBEAT.json"
TELEGRAM_BOT_HEARTBEAT = STATE_ROOT / "TELEGRAM_BOT_HEARTBEAT.json"


def is_process_guard_healthy(pid: int | None) -> bool:
    try:
        import psutil
        observed = fingerprint(psutil.Process(pid))
        heartbeat = json.loads(PROCESS_GUARD_HEARTBEAT.read_text(encoding="utf-8"))
        return health(observed, observed, heartbeat)["healthy"] is True
    except Exception:
        return False


def is_telegram_bot_healthy(pid: int | None) -> bool:
    try:
        import psutil
        observed = fingerprint(psutil.Process(pid))
        heartbeat = json.loads(TELEGRAM_BOT_HEARTBEAT.read_text(encoding="utf-8"))
        return health(observed, observed, heartbeat)["healthy"] is True
    except Exception:
        return False


def get_running_services() -> dict[str, int | None]:
    """Return identity-verified alive services; health is separately reported, never killed."""
    result = {name: None for name in ("companion_bridge", "process_guard", "telegram_bot")}
    specs = {"companion_bridge":(COMPANION_BRIDGE_JS,("watch",)), "process_guard":(PROCESS_GUARD_PY,("--watch",)), "telegram_bot":(TELEGRAM_BOT_PY,())}
    try:
        import psutil
        for process in psutil.process_iter():
            try:
                argv=process.cmdline()
                for name,(script,required) in specs.items():
                    if command_matches(argv,script,required):
                        observed=fingerprint(process)
                        result[name]=observed["pid"]
                        save_supervisor_pid(name,observed["pid"])
                        if name in {"process_guard","telegram_bot"}:
                            hb=PROCESS_GUARD_HEARTBEAT if name=="process_guard" else TELEGRAM_BOT_HEARTBEAT
                            heartbeat=json.loads(hb.read_text(encoding="utf-8")) if hb.is_file() else None
                            report=health(observed,observed,heartbeat)
                            if report["healthy"] is not True:log_event("[HEALTH_UNKNOWN] "+name+":"+report["reason"])
            except (psutil.NoSuchProcess,psutil.AccessDenied,OSError,ValueError):
                continue
    except ImportError:
        log_event("[CAPABILITY_HOLD] psutil required to verify command and creation time")
    return result


def _unfenced_start_companion_bridge() -> bool:
    if not NODE_EXE.is_file() or not COMPANION_BRIDGE_JS.is_file():
        log_event("Cannot start Companion Bridge: node or script missing")
        return False

    out_log = LOG_DIR / "companion_bridge_service.log"
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    log_event("Starting Companion Bridge (node companion_bridge.js watch)...")
    try:
        out_f = open(out_log, "a", encoding="utf-8")
        proc = subprocess.Popen(
            [str(NODE_EXE), str(COMPANION_BRIDGE_JS), "watch"],
            cwd=str(COMPANION_BRIDGE_JS.parent.parent),
            stdout=out_f,
            stderr=out_f,
            creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS,
            close_fds=True
        )
        log_event(f"Companion Bridge started with PID {proc.pid}")
        save_supervisor_pid("companion_bridge", proc.pid)
        return True
    except Exception as e:
        log_event(f"Failed to start Companion Bridge: {e}")
        return False


def _unfenced_start_action_bridge() -> bool:
    log_event('[IMPORT_HOLD] Automatic import belongs to transport_v2; raw Downloads watcher is retired')
    return False


def _unfenced_start_process_guard() -> bool:
    if not PYTHONW_EXE.is_file() or not PROCESS_GUARD_PY.is_file():
        log_event("Cannot start Process Guard: pythonw or script missing")
        return False

    out_log = LOG_DIR / "process_guard_service.log"
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    log_event("Starting Process Guard (antigravity_process_guard.py --watch)...")
    try:
        out_f = open(out_log, "a", encoding="utf-8")
        args = [
            str(PYTHONW_EXE),
            "-u",
            str(PROCESS_GUARD_PY),
            "--watch"
        ]
        proc = subprocess.Popen(
            args,
            cwd=str(PROCESS_GUARD_PY.parent),
            stdout=out_f,
            stderr=out_f,
            creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS,
            close_fds=True
        )
        log_event(f"Process Guard started with PID {proc.pid}")
        save_supervisor_pid("process_guard", proc.pid)
        return True
    except Exception as e:
        log_event(f"Failed to start Process Guard: {e}")
        return False


def _unfenced_start_telegram_bot() -> bool:
    if not PYTHON_EXE.is_file() or not TELEGRAM_BOT_PY.is_file():
        log_event("Cannot start Telegram Bot: python or script missing")
        return False

    out_log = LOG_DIR / "telegram_bot_service.log"
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    log_event("Starting Telegram Remote Cycle Bot (telegram_cycle_bot.py)...")
    try:
        out_f = open(out_log, "a", encoding="utf-8")
        args = [
            str(PYTHON_EXE),
            "-u",
            str(TELEGRAM_BOT_PY)
        ]
        proc = subprocess.Popen(
            args,
            cwd=str(TELEGRAM_BOT_PY.parent),
            stdout=out_f,
            stderr=out_f,
            creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS,
            close_fds=True
        )
        log_event(f"Telegram Bot started with PID {proc.pid}")
        save_supervisor_pid("telegram_bot", proc.pid)
        return True
    except Exception as e:
        log_event(f"Failed to start Telegram Bot: {e}")
        return False


def ensure_all_services() -> dict[str, int | None]:
    services=get_running_services()
    starters={"companion_bridge":start_companion_bridge,"process_guard":start_process_guard,"telegram_bot":start_telegram_bot}
    for name,starter in starters.items():
        if services.get(name) is None:starter()
    # Antigravity IDE is managed interactively or by quota_recovery_engine during account rotation
    return get_running_services()


def watch_loop(interval: float = 10.0) -> None:
    log_event(f"Agentic Cyclic Supervisor started in daemon mode (interval {interval}s)")
    try:
        while True:
            services = get_running_services()
            if services["companion_bridge"] is None:
                log_event("Companion Bridge is DOWN. Reviving...")
                start_companion_bridge()
            if services["process_guard"] is None:
                log_event("Process Guard is DOWN. Reviving...")
                start_process_guard()
            if services["telegram_bot"] is None:
                log_event("Telegram Bot is DOWN. Reviving...")
                start_telegram_bot()

            time.sleep(interval)
    except KeyboardInterrupt:
        log_event("Supervisor stopped by user.")


def main() -> int:
    parser=argparse.ArgumentParser(description="Agentic Cyclic System Supervisor")
    parser.add_argument("--watch",action="store_true");parser.add_argument("--interval",type=float,default=10.0);parser.add_argument("--ensure",action="store_true")
    parser.add_argument("--expected-epoch",type=int);parser.add_argument("--operation-id")
    args=parser.parse_args()
    if (args.expected_epoch is None)!=(args.operation_id is None):parser.error("expected epoch and operation id must be provided together")
    if args.watch:
        if args.operation_id is not None:parser.error("delegated operation only supports --ensure")
        watch_loop(args.interval);return 0
    import contextlib
    with contextlib.redirect_stdout(sys.stderr):result=ensure_report(args.expected_epoch,args.operation_id)
    print(json.dumps(result,ensure_ascii=False))
    return 0 if result["success"] else 2


if __name__ == "__main__":
    sys.exit(main())
