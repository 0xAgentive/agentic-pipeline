#!/usr/bin/env python3
"""
daemon_supervisor.py - Decoupled Daemon Lifecycle Manager for Agentic Pipeline.

Ensures companion_bridge, process_guard, and telegram_cycle_bot run as independent,
detached OS processes that survive Antigravity IDE restarts and process kills.
"""

import os
import sys
import json
import time
import subprocess
from pathlib import Path



try:
    import psutil
except ImportError:
    psutil = None

_GLOBAL_SUPERVISOR_MUTEX = {}

def acquire_singleton_mutex(name: str):
    """Acquires a system-wide named mutex and file-based PID lock on Windows without elevation."""
    if sys.platform != "win32":
        return True
    global _GLOBAL_SUPERVISOR_MUTEX

    # 1. Named Win32 Mutex across Global and Local namespaces
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        for prefix in ("Global\\", "Local\\"):
            handle = kernel32.CreateMutexW(None, True, f"{prefix}{name}")
            err = ctypes.get_last_error()
            if not handle or err == 183:  # ERROR_ALREADY_EXISTS
                if handle:
                    kernel32.CloseHandle(handle)
                return None
            if handle:
                _GLOBAL_SUPERVISOR_MUTEX[name] = handle
                break
    except Exception:
        pass

    # 2. Resilient file-based PID lock
    try:
        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        lock_file = LOGS_DIR / f"{name}.lock"
        my_pid = os.getpid()
        if lock_file.is_file():
            try:
                old_pid = int(lock_file.read_text(encoding="utf-8").strip())
                if old_pid != my_pid:
                    if psutil and psutil.pid_exists(old_pid):
                        return None
                    import ctypes
                    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, old_pid)
                    if h:
                        ctypes.windll.kernel32.CloseHandle(h)
                        return None
            except Exception:
                pass
        lock_fd = open(lock_file, "w", encoding="utf-8")
        lock_fd.write(str(my_pid))
        lock_fd.flush()
        _GLOBAL_SUPERVISOR_MUTEX[f"{name}_file"] = lock_fd
        return True
    except Exception:
        return True

PIPELINE_ROOT = Path(r"C:\Users\Администратор\Documents\antigravity\Agentic Pipeline")
LOGS_DIR = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\logs")
NODE_EXE = r"C:\Program Files\nodejs\node.exe"
PYTHON_EXE = r"C:\Users\Администратор\AppData\Local\Programs\Python\Python314\python.exe"


DAEMONS = [
    {
        "id": "companion_bridge",
        "cmd": [NODE_EXE, "--max-old-space-size=512", "--expose-gc", "--no-warnings", str(PIPELINE_ROOT / "scripts" / "companion_bridge.js"), "watch"],
        "cwd": str(PIPELINE_ROOT),
        "log_file": str(LOGS_DIR / "companion_bridge_service.log"),
        "match": ["companion_bridge.js", "watch"]
    },
    {
        "id": "process_guard",
        "cmd": [PYTHON_EXE, "-u", str(PIPELINE_ROOT / "scripts" / "antigravity_process_guard.py"), "--watch"],
        "cwd": str(PIPELINE_ROOT),
        "log_file": str(LOGS_DIR / "process_guard_service.log"),
        "match": ["antigravity_process_guard.py", "--watch"]
    },
    {
        "id": "telegram_bot",
        "cmd": [PYTHON_EXE, "-u", str(PIPELINE_ROOT / "scripts" / "telegram_cycle_bot.py")],
        "cwd": str(PIPELINE_ROOT),
        "log_file": str(LOGS_DIR / "telegram_cycle_bot_service.log"),
        "match": ["telegram_cycle_bot.py"]
    },
    {
        "id": "antigravity_tools",
        "cmd": [r"C:\Users\Администратор\AppData\Local\Antigravity Tools\antigravity-tools.exe"],
        "cwd": r"C:\Users\Администратор\AppData\Local\Antigravity Tools",
        "log_file": str(LOGS_DIR / "antigravity_tools_service.log"),
        "match": ["antigravity-tools.exe"]
    }
]

DETACHED_PROCESS = 0x00000008
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000

# Path to the shared standby state written by the Telegram bot's pause command.
# When is_standby=True the supervisor must NOT restart daemons — doing so would
# create a restart loop that defeats the owner's explicit pause.
_STANDBY_STATE_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\STANDBY_STATE.json")


def is_standby_active() -> bool:
    """Return True if owner has explicitly paused the pipeline via Telegram."""
    try:
        if _STANDBY_STATE_PATH.is_file():
            data = json.loads(_STANDBY_STATE_PATH.read_text(encoding="utf-8"))
            return bool(data.get("is_standby", False))
    except Exception:
        pass
    return False


def is_daemon_running(daemon_def):
    pid_file = LOGS_DIR / f"{daemon_def['id']}.pid"
    if pid_file.is_file():
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
            if psutil and psutil.pid_exists(pid):
                p = psutil.Process(pid)
                try:
                    cmd_str = " ".join(p.cmdline() or []).lower()
                    if all(t.lower() in cmd_str for t in daemon_def["match"]):
                        return pid
                except (psutil.AccessDenied, psutil.NoSuchProcess):
                    pass
                # Fallback if cmdline query failed due to Windows permissions: verify by process name
                pname = (p.name() or "").lower()
                expected = "node" if daemon_def["id"] == "companion_bridge" else (
                    "antigravity-tools" if daemon_def["id"] == "antigravity_tools" else "python"
                )
                if expected in pname:
                    return pid
        except Exception:
            pass

    if not psutil:
        return None

    match_tokens = daemon_def["match"]
    for p in psutil.process_iter(['pid', 'name', 'cmdline']):
        try:
            cmdline = p.info.get('cmdline') or []
            cmd_str = " ".join(cmdline).lower()
            if all(token.lower() in cmd_str for token in match_tokens):
                try:
                    pid_file.write_text(str(p.info['pid']), encoding="utf-8")
                except Exception:
                    pass
                return p.info['pid']
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return None


def rotate_log_if_oversized(log_path_str: str, max_bytes: int = 5 * 1024 * 1024) -> None:
    p = Path(log_path_str)
    if p.is_file():
        try:
            size = p.stat().st_size
            if size > max_bytes:
                old_p = p.with_name(p.name + ".old")
                with open(p, "rb") as f:
                    f.seek(max(0, size - 256 * 1024))
                    tail = f.read()
                with open(old_p, "wb") as f_old:
                    f_old.write(tail)
                with open(p, "wb") as f_curr:
                    f_curr.write(tail[-32768:])
                print(f"[SUPERVISOR] Rotated oversized log: {p.name}")
        except Exception:
            pass


def start_daemon(daemon_def):
    pid = is_daemon_running(daemon_def)
    if pid:
        print(f"[SUPERVISOR] {daemon_def['id']} is already running (PID: {pid})")
        return pid

    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    rotate_log_if_oversized(daemon_def["log_file"])
    out_log = open(daemon_def["log_file"], "a", encoding="utf-8")
    flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
    if daemon_def.get("id") in ("antigravity_tools", "process_guard"):
        flags = CREATE_NEW_PROCESS_GROUP

    env = os.environ.copy()
    if "SystemRoot" not in env and "SYSTEMROOT" in env:
        env["SystemRoot"] = env["SYSTEMROOT"]
    elif "SystemRoot" not in env:
        env["SystemRoot"] = r"C:\Windows"
    if "windir" not in env:
        env["windir"] = env["SystemRoot"]
    python_dir = os.path.dirname(sys.executable)
    dll_dir = os.path.join(python_dir, "DLLs")
    env["PATH"] = python_dir + os.pathsep + dll_dir + os.pathsep + r"C:\Windows\System32" + os.pathsep + env.get("PATH", "")

    proc = subprocess.Popen(
        daemon_def["cmd"],
        cwd=daemon_def["cwd"],
        stdin=subprocess.DEVNULL,
        stdout=out_log,
        stderr=out_log,
        creationflags=flags,
        env=env,
        close_fds=True
    )
    try:
        (LOGS_DIR / f"{daemon_def['id']}.pid").write_text(str(proc.pid), encoding="utf-8")
    except Exception:
        pass
    print(f"[SUPERVISOR] Spawned detached {daemon_def['id']} (PID: {proc.pid})")
    return proc.pid


def reconcile_coordinator_state():
    import sqlite3
    now = time.time()
    db_path = Path(os.path.expandvars(r"%USERPROFILE%\.agentic-pipeline\action-bridge\RECOVERY_STATE.sqlite3"))
    if not db_path.is_file():
        return
    try:
        import json
        with sqlite3.connect(str(db_path), timeout=5) as conn:
            conn.execute("PRAGMA busy_timeout=5000")
            if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='v2_effect_lease'").fetchone():
                row = conn.execute("SELECT data FROM v2_effect_lease WHERE id=1").fetchone()
                if row and json.loads(row[0]).get("expires_at", 0) <= now:
                    conn.execute("DELETE FROM v2_effect_lease")
            if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='v2_effects'").fetchone():
                rows = conn.execute("SELECT project, operation_id, data FROM v2_effects WHERE json_extract(data,'$.status') IN ('DISPATCHED','UNCERTAIN')").fetchall()
                for proj, op_id, data_str in rows:
                    edata = json.loads(data_str)
                    if edata.get("expires_at", 0) < now:
                        edata.update(status="FAILED_SAFE", evidence_ref="SUPERVISOR_PREFLIGHT_SWEEP", retry_at=0)
                        conn.execute("UPDATE v2_effects SET data=? WHERE project=? AND operation_id=?", (json.dumps(edata), proj, op_id))
            conn.commit()
            print("[SUPERVISOR] Coordinator state pre-flight sweep completed.")
    except Exception as e:
        print(f"[SUPERVISOR] Coordinator pre-flight sweep notice: {e}")


def stop_daemon(daemon_def):
    pid = is_daemon_running(daemon_def)
    if not pid:
        print(f"[SUPERVISOR] {daemon_def['id']} is not running.")
        return True
    try:
        p = psutil.Process(pid)
        p.terminate()
        try:
            p.wait(timeout=5)
        except psutil.TimeoutExpired:
            p.kill()
        print(f"[SUPERVISOR] Stopped {daemon_def['id']} (PID: {pid})")
        return True
    except Exception as e:
        print(f"[SUPERVISOR] Failed to stop {daemon_def['id']} (PID: {pid}): {e}")
        return False


def restart_daemon(daemon_def):
    stop_daemon(daemon_def)
    time.sleep(1.0)
    reconcile_coordinator_state()
    return start_daemon(daemon_def)


SUPERVISOR_HEARTBEAT_PATH = LOGS_DIR.parent / "SUPERVISOR_HEARTBEAT.json"


def write_supervisor_heartbeat() -> None:
    try:
        data = {
            "pid": os.getpid(),
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "epoch": time.time()
        }
        tmp = SUPERVISOR_HEARTBEAT_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.replace(SUPERVISOR_HEARTBEAT_PATH)
    except Exception:
        pass


def is_watch_running() -> int | None:
    lock_file = LOGS_DIR / "AgenticPipeline_DaemonSupervisor_Watch.lock"
    my_pid = os.getpid()
    if lock_file.is_file():
        try:
            pid = int(lock_file.read_text(encoding="utf-8").strip())
            if pid != my_pid:
                if psutil and psutil.pid_exists(pid):
                    try:
                        p = psutil.Process(pid)
                        if "python" in (p.name() or "").lower():
                            return pid
                    except Exception:
                        return pid
                elif not psutil:
                    import ctypes
                    h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
                    if h:
                        ctypes.windll.kernel32.CloseHandle(h)
                        return pid
        except Exception:
            pass

    if psutil:
        for p in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if p.info['pid'] == my_pid:
                    continue
                cmdline = p.info.get('cmdline') or []
                cmd_str = " ".join(cmdline).lower()
                if "daemon_supervisor.py" in cmd_str and ("--watch" in cmd_str or " watch" in cmd_str):
                    return p.info['pid']
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
    return None


def ensure_watch_daemon() -> int | None:
    pid = is_watch_running()
    if pid:
        return pid

    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    out_log = open(LOGS_DIR / "daemon_supervisor_service.log", "a", encoding="utf-8")
    flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP

    proc = subprocess.Popen(
        [PYTHON_EXE, "-u", str(Path(__file__).resolve()), "--watch"],
        cwd=str(PIPELINE_ROOT),
        stdin=subprocess.DEVNULL,
        stdout=out_log,
        stderr=out_log,
        creationflags=flags,
        close_fds=True
    )
    print(f"[SUPERVISOR] Spawned detached daemon supervisor watcher (PID: {proc.pid})")
    return proc.pid


def ensure_all_daemons(spawn_watch: bool = True) -> dict[str, str]:
    reconcile_coordinator_state()
    try:
        import sync_agent_directives
        sync_agent_directives.sync_directives()
    except Exception:
        pass
    results = {}
    for d in DAEMONS:
        pid = is_daemon_running(d)
        if not pid:
            pid = start_daemon(d)
            results[d["id"]] = f"started (PID {pid})"
        else:
            results[d["id"]] = f"running (PID {pid})"

    if spawn_watch:
        w_pid = is_watch_running()
        if not w_pid:
            w_pid = ensure_watch_daemon()
            results["supervisor_watch"] = f"started (PID {w_pid})"
        else:
            results["supervisor_watch"] = f"running (PID {w_pid})"

    return results


def watch_loop(poll_interval: float = 15.0) -> None:
    print(f"[SUPERVISOR] Entering daemon supervisor watch loop (interval: {poll_interval}s, PID: {os.getpid()})...")
    last_sweep = 0.0
    last_standby_log = 0.0
    _daemon_last_start = {}
    while True:
        try:
            write_supervisor_heartbeat()
            now = time.time()
            if now - last_sweep >= 300.0:
                reconcile_coordinator_state()
                try:
                    import sync_agent_directives
                    sync_agent_directives.sync_directives()
                except Exception:
                    pass
                for d in DAEMONS:
                    rotate_log_if_oversized(d["log_file"])
                try:
                    from prune_transport_context import prune_transport_context
                    prune_transport_context(keep_count=5)
                except Exception:
                    pass
                try:
                    from cleanup_zombie_processes import clean_orphans
                    clean_orphans()
                except Exception:
                    pass
                last_sweep = now

            # ---------------------------------------------------------------
            # STANDBY GATE: if owner paused via Telegram, do NOT restart
            # any daemons. Log once per minute so the log doesn't flood.
            # ---------------------------------------------------------------
            if is_standby_active():
                if now - last_standby_log >= 60.0:
                    print(f"[SUPERVISOR] Pipeline is paused (STANDBY). Daemon restarts suppressed.")
                    last_standby_log = now
                time.sleep(poll_interval)
                continue

            for d in DAEMONS:
                pid = is_daemon_running(d)
                if not pid:
                    last_start = _daemon_last_start.get(d["id"], 0.0)
                    if now - last_start < 30.0:
                        continue
                    print(f"[SUPERVISOR] {d['id']} died, restarting...")
                    _daemon_last_start[d["id"]] = now
                    start_daemon(d)

            time.sleep(poll_interval)
        except KeyboardInterrupt:
            print("[SUPERVISOR] Exiting watch loop.")
            break
        except Exception as e:
            print(f"[SUPERVISOR] Error in loop: {e}")
            time.sleep(5.0)


if __name__ == "__main__":
    raw_mode = sys.argv[1] if len(sys.argv) > 1 else "--ensure"
    target_id = sys.argv[2] if len(sys.argv) > 2 else None
    mode = raw_mode.lower().lstrip("-")

    # Daemons that may start even during standby (control channel must stay alive).
    _STANDBY_EXEMPT = {"telegram_bot"}

    if mode in ("ensure", "start"):
        if target_id:
            found = False
            for d in DAEMONS:
                if d["id"] == target_id:
                    # Respect standby for non-exempt targets
                    if is_standby_active() and d["id"] not in _STANDBY_EXEMPT:
                        print(f"[SUPERVISOR] Standby active — skipping start of {d['id']}")
                    else:
                        p = start_daemon(d)
                        print(f"  {d['id']}: started (PID {p})")
                    found = True
                    break
            if not found:
                if target_id == "supervisor_watch":
                    if is_standby_active():
                        print("[SUPERVISOR] Standby active — not starting supervisor_watch")
                    else:
                        p = ensure_watch_daemon()
                        print(f"  supervisor_watch: started (PID {p})")
                else:
                    print(f"[SUPERVISOR] Unknown daemon target: {target_id}")
        else:
            if is_standby_active():
                print("[SUPERVISOR] Standby active — starting ONLY telegram_bot (control channel)")
                for d in DAEMONS:
                    if d["id"] in _STANDBY_EXEMPT:
                        pid = is_daemon_running(d)
                        if not pid:
                            pid = start_daemon(d)
                        print(f"  {d['id']}: running (PID {pid})")
                    else:
                        print(f"  {d['id']}: SKIPPED (standby)")
            else:
                res = ensure_all_daemons(spawn_watch=True)
                for k, v in res.items():
                    print(f"  {k}: {v}")
    elif mode == "restart":
        reconcile_coordinator_state()
        if target_id == "supervisor_watch":
            if is_standby_active():
                print("[SUPERVISOR] Standby active — not restarting supervisor_watch")
            else:
                w_pid = is_watch_running()
                if w_pid:
                    try:
                        p = psutil.Process(w_pid)
                        p.terminate()
                        p.wait(timeout=5)
                    except Exception:
                        pass
                new_pid = ensure_watch_daemon()
                print(f"  supervisor_watch: restarted (PID {new_pid})")
        else:
            for d in DAEMONS:
                if not target_id or d["id"] == target_id:
                    if is_standby_active() and d["id"] not in _STANDBY_EXEMPT:
                        print(f"  {d['id']}: SKIPPED restart (standby)")
                    else:
                        restart_daemon(d)
            if not target_id and not is_standby_active():
                w_pid = is_watch_running()
                if not w_pid:
                    ensure_watch_daemon()
    elif mode == "stop":
        for d in DAEMONS:
            if not target_id or d["id"] == target_id:
                stop_daemon(d)
        if not target_id or target_id == "supervisor_watch":
            w_pid = is_watch_running()
            if w_pid:
                try:
                    p = psutil.Process(w_pid)
                    p.terminate()
                    p.wait(timeout=5)
                    print(f"[SUPERVISOR] Stopped supervisor_watch (PID: {w_pid})")
                except Exception as e:
                    print(f"[SUPERVISOR] Failed to stop supervisor_watch: {e}")
    elif mode == "watch":
        _supervisor_mutex = acquire_singleton_mutex("AgenticPipeline_DaemonSupervisor_Watch")
        if not _supervisor_mutex:
            print(f"[SUPERVISOR] Another daemon supervisor watcher is already running (PID {is_watch_running()}). Exiting.")
            sys.exit(0)
        if is_standby_active():
            print("[SUPERVISOR] Standby active — starting ONLY telegram_bot before entering watch loop")
            for d in DAEMONS:
                if d["id"] in _STANDBY_EXEMPT:
                    pid = is_daemon_running(d)
                    if not pid:
                        start_daemon(d)
        else:
            ensure_all_daemons(spawn_watch=False)
        watch_loop()
    elif mode == "status":
        standby_str = " [STANDBY ACTIVE]" if is_standby_active() else ""
        print(f"[SUPERVISOR] Status{standby_str}:")
        for d in DAEMONS:
            pid = is_daemon_running(d)
            print(f"  {d['id']}: {'RUNNING (PID ' + str(pid) + ')' if pid else 'STOPPED'}")
        w_pid = is_watch_running()
        print(f"  supervisor_watch: {'RUNNING (PID ' + str(w_pid) + ')' if w_pid else 'STOPPED'}")

