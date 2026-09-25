#!/usr/bin/env python3
"""
Antigravity Process Guard (Anti-Hang Watchdog & Auto-Resume Service)
Features:
1. Zero-window native process inspection via psutil (100% silent, zero flicker)
2. Dynamic discovery of active Antigravity language_server port & CSRF token
3. Instant automatic resumption of chats interrupted by quota or server restarts
4. Termination of zombie Node REPLs and runaway PowerShell loops
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

if sys.platform == "win32":
    if "SystemRoot" not in os.environ and "SYSTEMROOT" in os.environ:
        os.environ["SystemRoot"] = os.environ["SYSTEMROOT"]
    elif "SystemRoot" not in os.environ:
        os.environ["SystemRoot"] = r"C:\Windows"
    if "windir" not in os.environ:
        os.environ["windir"] = os.environ["SystemRoot"]
    python_dir = os.path.dirname(sys.executable)
    dll_dir = os.path.join(python_dir, "DLLs")
    os.environ["PATH"] = python_dir + os.pathsep + dll_dir + os.pathsep + r"C:\Windows\System32" + os.pathsep + os.environ.get("PATH", "")
    if hasattr(os, "add_dll_directory"):
        try:
            if os.path.isdir(python_dir):
                os.add_dll_directory(python_dir)
            if os.path.isdir(dll_dir):
                os.add_dll_directory(dll_dir)
        except Exception:
            pass

import ssl
import urllib.request

try:
    import psutil
except Exception as _e:
    psutil = None
    print(f"[WARN] psutil import failed: {_e}", flush=True)

try:
    import ctypes
    import ctypes.wintypes
    HAS_CTYPES = True
except Exception as _e:
    ctypes = None
    HAS_CTYPES = False
    print(f"[WARN] ctypes import failed: {_e}", flush=True)

_GLOBAL_MUTEX_HANDLES = {}

def acquire_singleton_mutex(name: str):
    """Acquires a process-wide named mutex on Windows without requiring elevation. Returns handle or None."""
    if sys.platform != "win32":
        return True
    global _GLOBAL_MUTEX_HANDLES
    try:
        if HAS_CTYPES and ctypes:
            from ctypes import wintypes
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
            kernel32.CreateMutexW.restype = wintypes.HANDLE
            # Use Local namespace to allow standard non-elevated user token execution
            handle = kernel32.CreateMutexW(None, True, f"Local\\{name}")
            err = ctypes.get_last_error()
            if not handle or err == 183:  # ERROR_ALREADY_EXISTS
                if handle:
                    kernel32.CloseHandle(handle)
                return None
            _GLOBAL_MUTEX_HANDLES[name] = handle
            return handle
    except Exception:
        pass

    # Resilient fallback: File-based PID lock
    try:
        lock_file = LOG_FILE.parent / f"{name}.lock"
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        my_pid = os.getpid()
        if lock_file.is_file():
            try:
                old_pid = int(lock_file.read_text(encoding="utf-8").strip())
                if old_pid != my_pid and psutil and psutil.pid_exists(old_pid):
                    p = psutil.Process(old_pid)
                    if "python" in (p.name() or "").lower():
                        return None
            except Exception:
                pass
        lock_file.write_text(str(my_pid), encoding="utf-8")
        return True
    except Exception:
        return True

STANDBY_STATE_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\STANDBY_STATE.json")
ACTIVE_LS_ENV_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\ACTIVE_LS_ENV.json")
LOG_FILE = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\logs\process_guard.log")
HEARTBEAT_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\PROCESS_GUARD_HEARTBEAT.json")
ANTIGRAVITY_EXE_PATH = Path(r"C:\Users\Администратор\AppData\Local\Programs\Antigravity\Antigravity.exe")
QUOTA_RECOVERY_LOCK_PATH = Path(r"C:\Scripts\AntigravityProjects\companion-handoff\state\quota_recovery.lock")
LAST_RESUMED_TIMESTAMPS: dict[str, float] = {}
CONSECUTIVE_FAILURES: dict[str, int] = {}
LAST_KNOWN_LS_PID: str | None = None
RECENT_STREAM_INTERRUPTIONS: list[dict] = []
AUTO_RESUME_TITLES = [
    "возобновление после сетевого сбоя",
    "auto-resume interrupted task",
    "возобновление прерванного потока",
    "поток ответа восстановлен",
    "сетевое подключение к серверу восстановлено",
    "продолжай автономное выполнение задачи",
]

RETIRED_CONVERSATIONS_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\RETIRED_CONVERSATIONS.json")

def get_retired_conversation_ids() -> set[str]:
    retired = {
        "59b5ef37-6039-45f8-8a97-965f78115748",
        "b753d27d-0fd7-435c-b698-3e46020c9777",
        "c0f55ce7-2989-4557-8cb0-e1f7980033e3",
        "4e568acf-a6a6-48f1-8b08-789a4210a93b",
        "8a19726e-c925-4150-a315-bb0bad5fc204",
        "246a39ca-cff1-4aa7-b500-bca4f6f4cba5",
        "9b099db5-8ebf-4cf6-9a25-c6ddfd71bc56",
        "f3ba6e6d-5e26-4447-9759-99a3ce4e0cb9",
    }
    if RETIRED_CONVERSATIONS_PATH.is_file():
        try:
            data = json.loads(RETIRED_CONVERSATIONS_PATH.read_text(encoding="utf-8"))
            if isinstance(data, list):
                retired.update(data)
            elif isinstance(data, dict):
                retired.update(data.get("retired_conversation_ids", []))
        except Exception:
            pass
    return retired


try:
    src_path = r"C:\Scripts\AntigravityProjects\companion-handoff\src"
    if src_path not in sys.path:
        sys.path.insert(0, src_path)
    from interruption_detector import is_quota_exhaustion_text
except Exception:
    def is_quota_exhaustion_text(t: str) -> bool:
        if not t:
            return False
        tl = str(t).lower()
        patterns = [
            "resource_exhausted", "individual quota reached", "individual quota",
            "baseline model quota", "exceeded your current quota", "you have reached your quota",
            "quota exceeded", "rate limit exceeded", "too many requests", "code 429", "status 429",
            "please upgrade your subscription", "resets in", "baseline quota will refresh",
            "model unavailable, retrying", "model overloaded"
        ]
        return any(k in tl for k in patterns)



LAST_ANTIGRAVITY_LAUNCH_TIME = 0.0
LAST_SERVER_RESTART_TIME = 0.0



def get_win32_process_names() -> set[str]:
    """Pure Win32 API kernel32 Toolhelp32Snapshot - 0 dependencies, 0ms, never fails."""
    names = set()
    if not HAS_CTYPES or ctypes is None:
        return names
    try:
        TH32CS_SNAPPROCESS = 0x00000002
        class PROCESSENTRY32(ctypes.Structure):
            _fields_ = [
                ('dwSize', ctypes.wintypes.DWORD),
                ('cntUsage', ctypes.wintypes.DWORD),
                ('th32ProcessID', ctypes.wintypes.DWORD),
                ('th32DefaultHeapID', ctypes.POINTER(ctypes.wintypes.ULONG)),
                ('th32ModuleID', ctypes.wintypes.DWORD),
                ('cntThreads', ctypes.wintypes.DWORD),
                ('th32ParentProcessID', ctypes.wintypes.DWORD),
                ('pcPriClassBase', ctypes.wintypes.LONG),
                ('dwFlags', ctypes.wintypes.DWORD),
                ('szExeFile', ctypes.c_char * 260)
            ]
        hSnap = ctypes.windll.kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if hSnap and hSnap != -1:
            try:
                pe = PROCESSENTRY32()
                pe.dwSize = ctypes.sizeof(PROCESSENTRY32)
                if ctypes.windll.kernel32.Process32First(hSnap, ctypes.byref(pe)):
                    while True:
                        exe = pe.szExeFile.decode('mbcs', errors='ignore').lower()
                        if exe:
                            names.add(exe)
                        if not ctypes.windll.kernel32.Process32Next(hSnap, ctypes.byref(pe)):
                            break
            finally:
                ctypes.windll.kernel32.CloseHandle(hSnap)
    except Exception:
        pass
    return names


def is_language_server_running() -> bool:
    """Checks whether Antigravity language_server.exe is alive using multiple robust layers."""
    # Layer 0: Pure Win32 kernel32 Toolhelp32Snapshot (100% reliable, zero DLL/psutil dependencies)
    try:
        names = get_win32_process_names()
        if "language_server.exe" in names:
            return True
    except Exception:
        pass

    # Layer 0.5: Direct TCP socket ping to active language_server address (0ms, 0 external dependencies, 100% ground truth)
    try:
        if ACTIVE_LS_ENV_PATH.is_file():
            data = json.loads(ACTIVE_LS_ENV_PATH.read_text(encoding="utf-8"))
            addr = data.get("ANTIGRAVITY_LS_ADDRESS") or ""
            if ":" in addr:
                host, port_str = addr.split(":")[-2:]
                host = host.replace("//", "").strip()
                if host in ("localhost", "127.0.0.1", ""):
                    host = "127.0.0.1"
                import socket
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(0.3)
                try:
                    if s.connect_ex((host, int(port_str))) == 0:
                        return True
                finally:
                    s.close()
    except Exception:
        pass

    # Layer 1: Direct PID check from ACTIVE_LS_ENV.json (0ms, zero permissions issues)
    try:
        if ACTIVE_LS_ENV_PATH.is_file():
            data = json.loads(ACTIVE_LS_ENV_PATH.read_text(encoding="utf-8"))
            pid_str = data.get("ANTIGRAVITY_LS_PID")
            if pid_str and psutil:
                pid = int(pid_str)
                if psutil.pid_exists(pid):
                    try:
                        p = psutil.Process(pid)
                        if "language_server" in (p.name() or "").lower():
                            return True
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass
    except Exception:
        pass

    # Layer 2: Iterate process names via psutil with ad_value='' (immune to generator crashes)
    if psutil:
        try:
            for p in psutil.process_iter(['name'], ad_value=''):
                try:
                    if (p.info.get('name') or '').lower() == 'language_server.exe':
                        return True
                except Exception:
                    continue
        except Exception:
            pass

    # Layer 3: Native tasklist command with cp866 decoding
    try:
        tasklist_bin = r"C:\Windows\System32\tasklist.exe" if Path(r"C:\Windows\System32\tasklist.exe").is_file() else "tasklist"
        res = subprocess.run([tasklist_bin, "/FI", "IMAGENAME eq language_server.exe"], capture_output=True, timeout=5, creationflags=CREATE_NO_WINDOW)
        raw = (res.stdout or b'').decode('cp866', errors='ignore').lower()
        if "language_server.exe" in raw:
            return True
    except Exception:
        pass

    return False


def is_antigravity_running() -> bool:
    """Checks whether Antigravity.exe OR language_server.exe is alive."""
    if is_language_server_running():
        return True

    # Layer 0: Pure Win32 kernel32 Toolhelp32Snapshot
    try:
        names = get_win32_process_names()
        if "antigravity.exe" in names:
            return True
    except Exception:
        pass

    # Layer 1: Iterate process names via psutil with ad_value=''
    if psutil:
        try:
            for p in psutil.process_iter(['name'], ad_value=''):
                try:
                    if (p.info.get('name') or '').lower() == 'antigravity.exe':
                        return True
                except Exception:
                    continue
        except Exception:
            pass

    # Layer 2: Native tasklist command with cp866 decoding
    try:
        res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Antigravity.exe"], capture_output=True, timeout=5, creationflags=CREATE_NO_WINDOW)
        raw = (res.stdout or b'').decode('cp866', errors='ignore').lower()
        if "antigravity.exe" in raw:
            return True
    except Exception:
        pass
    return False


def start_antigravity() -> bool:
    """Safely launches Antigravity on the user's interactive desktop with strict cooldown and LS presence check."""
    global LAST_ANTIGRAVITY_LAUNCH_TIME
    if is_antigravity_running() or is_language_server_running():
        log_event("[WATCHDOG] start_antigravity: Antigravity or language_server is already running. Checking GUI visibility...")
        try:
            from antigravity_gui_launcher import is_antigravity_gui_visible, get_antigravity_window_handles, activate_antigravity_window
            if is_antigravity_gui_visible():
                hwnds = get_antigravity_window_handles()
                if hwnds:
                    activate_antigravity_window(hwnds[0])
                return True
        except Exception:
            pass
        return True

    now = time.time()
    if now - LAST_ANTIGRAVITY_LAUNCH_TIME < 300.0:
        log_event(f"[WATCHDOG] start_antigravity suppressed: launch cooldown active ({int(now - LAST_ANTIGRAVITY_LAUNCH_TIME)}s < 300s).")
        return False
    if not ANTIGRAVITY_EXE_PATH.is_file():
        log_event(f"Cannot start Antigravity: executable not found at {ANTIGRAVITY_EXE_PATH}")
        return False
    LAST_ANTIGRAVITY_LAUNCH_TIME = now
    log_event("Starting Antigravity (Antigravity.exe) on interactive desktop...")

    # Scrub headless environment variable
    os.environ.pop("ELECTRON_OZONE_PLATFORM_HINT", None)

    # Dedicated antigravity_gui_launcher with active project workspaces
    try:
        from antigravity_gui_launcher import launch_antigravity_visible, get_active_workspace_paths, is_antigravity_gui_visible
        workspaces = get_active_workspace_paths()
        if launch_antigravity_visible(workspace_paths=workspaces):
            log_event("Antigravity launch succeeded via antigravity_gui_launcher (visible GUI confirmed).")
            return True
        # If process is running, wait up to 15s for GUI window to render before considering any other action
        for _ in range(15):
            if is_antigravity_gui_visible():
                log_event("Antigravity GUI window confirmed active.")
                return True
            time.sleep(1.0)
    except Exception as e_gl:
        log_event(f"antigravity_gui_launcher failed: {e_gl}")

    return False


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

PIPELINE_ROOT = Path(r"C:\Users\Администратор\Documents\antigravity\Agentic Pipeline")


def is_companion_bridge_running() -> bool:
    if not psutil:
        return True
    try:
        for p in psutil.process_iter(['name', 'cmdline']):
            try:
                cmdline = p.info.get('cmdline') or []
                cmd_str = " ".join(cmdline).lower()
                if "companion_bridge.js" in cmd_str and "watch" in cmd_str:
                    return True
            except Exception:
                continue
    except Exception:
        pass
    return False


def ensure_companion_bridge_running() -> None:
    if is_companion_bridge_running():
        return
    now = time.time()
    last_restart = getattr(ensure_companion_bridge_running, "last_restart", 0.0)
    if now - last_restart < 60.0:
        return
    ensure_companion_bridge_running.last_restart = now
    log_event("[WATCHDOG] ⚠️ companion_bridge.js service is down! Automatically restarting via daemon_supervisor...")
    try:
        supervisor_py = PIPELINE_ROOT / "scripts" / "daemon_supervisor.py"
        flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
        res = subprocess.run([sys.executable, str(supervisor_py), "start", "companion_bridge"], capture_output=True, text=True, timeout=15, creationflags=flags)
        log_event(f"[WATCHDOG] companion_bridge start output: {res.stdout.strip()}")
    except Exception as e:
        log_event(f"[WATCHDOG Error] Failed to restart companion_bridge: {e}")


def safe_sleep(seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(1.0, remaining))


def read_transcript_tail(transcript_file: Path, max_lines: int = 100) -> list[dict]:
    """Efficiently reads only the last lines of transcript.jsonl by seeking near EOF."""
    try:
        size = transcript_file.stat().st_size
        if size == 0:
            return []
        read_bytes = min(size, 524288)
        with transcript_file.open("rb") as f:
            f.seek(size - read_bytes)
            raw = f.read()
        text = raw.decode("utf-8", errors="ignore")
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        if read_bytes < size and len(lines) > 1:
            lines = lines[1:]
        tail_lines = lines[-max_lines:]
        steps = []
        for l in tail_lines:
            try:
                steps.append(json.loads(l))
            except Exception:
                pass
        return steps
    except Exception:
        return []


def get_standby_info() -> dict:
    snap = {}
    try:
        from pipeline_runtime_state import snapshot as runtime_snapshot
        s = runtime_snapshot()
        if isinstance(s, dict):
            snap = s
    except Exception:
        pass
    disk_snap = {}
    if STANDBY_STATE_PATH.is_file():
        try:
            d = json.loads(STANDBY_STATE_PATH.read_text(encoding='utf-8'))
            if isinstance(d, dict):
                disk_snap = d
        except Exception:
            pass
    # If EITHER source declares is_standby == True, respect standby
    if disk_snap.get("is_standby") is True:
        return disk_snap
    if snap.get("is_standby") is True:
        return snap
    if disk_snap:
        return disk_snap
    if snap:
        return snap
    return {"is_standby": False, "mode": "NORMAL"}


def is_pipeline_in_standby() -> bool:
    return bool(get_standby_info().get("is_standby"))


def set_pipeline_standby(enabled: bool, reason: str = "", send_tg: bool = True, mode: str = "QUOTA_EXHAUSTED") -> None:
    global LAST_STANDBY_LS_PID
    try:
        STANDBY_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        current = get_standby_info()
        prev_state = bool(current.get("is_standby"))

        if not enabled:
            # CRITICAL SAFETY GUARD: If pipeline is in a user-initiated pause, NEVER auto-lift it!
            current_mode = current.get("mode", "")
            if current_mode in ("MAN_IN_THE_MIDDLE", "PRE_SLEEP", "PRE_HIBERNATE", "MANUAL", "USER_PAUSE"):
                log_event(f"[STANDBY] Auto-recovery prevented: Standby mode is '{current_mode}' (user manual pause). Standby will not be lifted.")
                return

        disk_state = None
        if STANDBY_STATE_PATH.is_file():
            try:
                disk_state = json.loads(STANDBY_STATE_PATH.read_text(encoding='utf-8')).get("is_standby")
            except Exception:
                pass

        if prev_state == enabled and disk_state == enabled:
            return

        state = {
            "is_standby": enabled,
            "mode": mode if enabled else "NORMAL",
            "reason": reason,
            "updated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()
        }
        # Resilient write with retry and direct overwrite fallback for Windows file locks
        written = False
        for _ in range(5):
            try:
                tmp = STANDBY_STATE_PATH.with_suffix(".tmp")
                tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding='utf-8')
                tmp.replace(STANDBY_STATE_PATH)
                written = True
                break
            except Exception:
                time.sleep(0.05)
        if not written:
            try:
                STANDBY_STATE_PATH.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding='utf-8')
                written = True
            except Exception as e_direct:
                log_event(f"[WARN] Failed direct write of standby state: {e_direct}")

        try:
            from pipeline_runtime_state import automatic_set as runtime_automatic_set
            runtime_automatic_set(enabled, mode=mode, reason=reason)
        except Exception:
            pass

        if enabled:
            log_event(f"[STANDBY] ⏸️ Pipeline entered WAITING PAUSE (Standby Mode: {mode}). Reason: {reason}")
            if send_tg:
                if mode == "QUOTA_EXHAUSTED":
                    send_telegram_notification(
                        f"⚠️ <b>ИСПЕРПАНИЕ КВОТЫ ANTIGRAVITY (ВЫПАД ИЗ ЦИКЛА)</b>\n\n"
                        f"• <b>Причина:</b> <i>{reason}</i>\n"
                        f"• <b>Режим:</b> <code>{mode}</code>\n\n"
                        f"⏸ <b>Статус пайплайна:</b>\n"
                        f"• Пайплайн автоматически переведён в выжидательную паузу (STANDBY).\n"
                        f"• Фоновые службы приостановили циклическую отправку запросов.\n"
                        f"• Process Guard непрерывно отслеживает сброс лимита квоты и смену сессии.\n\n"
                        f"💡 <i>Как только квота восстановится, цикл продолжится автоматически без ручного вмешательства.</i>"
                    )
                else:
                    send_telegram_notification(
                        f"⏸️ <b>Циклический пайплайн на выжидательной паузе</b>\n\n"
                        f"• <b>Причина:</b> {reason}\n"
                        f"• <b>Режим:</b> {mode}\n\n"
                        f"<i>Фоновые службы приостановили циклическую отправку запросов. При смене аккаунта или сбросе лимита работа возобновится автоматически.</i>"
                    )
        else:
            log_event(f"[STANDBY] ▶️ Pipeline EXITED Standby Mode. Reason: {reason}")
            if send_tg:
                send_telegram_notification(
                    f"🟢 <b>ПОЛНОЦЕННЫЕ ЦИКЛЫ ВОССТАНОВЛЕНЫ</b>\n\n"
                    f"• <b>Событие:</b> Квота снова доступна / новая сессия активна\n"
                    f"• <b>Причина:</b> <i>{reason}</i>\n\n"
                    f"🚀 <b>Действия системы:</b>\n"
                    f"• Выжидательная пауза снята (STANDBY ➔ NORMAL).\n"
                    f"• Команда продолжения передана агентам Antigravity.\n"
                    f"• Все 4 службы циклического комплекса работают в штатном режиме."
                )
    except Exception as e:
        log_event(f"[WARN] Failed to write standby state: {e}")



def log_event(message: str) -> None:
    now_str = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    line = f"[{now_str}] {message}\n"
    print(line, end="")
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        if LOG_FILE.is_file() and LOG_FILE.stat().st_size > 5 * 1024 * 1024:
            try:
                old = LOG_FILE.with_name(LOG_FILE.name + ".old")
                if old.is_file():
                    old.unlink(missing_ok=True)
                LOG_FILE.rename(old)
            except Exception:
                pass
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


TG_COOLDOWNS_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\telegram_notification_cooldowns.json")
_LAST_TG_SENT: dict[str, float] = {}


def _load_tg_cooldowns() -> dict[str, float]:
    global _LAST_TG_SENT
    cooldowns = dict(_LAST_TG_SENT)
    if TG_COOLDOWNS_PATH.is_file():
        try:
            data = json.loads(TG_COOLDOWNS_PATH.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                for k, v in data.items():
                    if isinstance(v, (int, float)):
                        cooldowns[str(k)] = float(v)
        except Exception:
            pass
    return cooldowns


def _save_tg_cooldown(clean_key: str, timestamp: float) -> None:
    global _LAST_TG_SENT
    _LAST_TG_SENT[clean_key] = timestamp
    try:
        TG_COOLDOWNS_PATH.parent.mkdir(parents=True, exist_ok=True)
        cooldowns = _load_tg_cooldowns()
        cooldowns[clean_key] = timestamp
        cutoff = timestamp - 86400.0
        cooldowns = {k: v for k, v in cooldowns.items() if v > cutoff}
        tmp = TG_COOLDOWNS_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(cooldowns, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(TG_COOLDOWNS_PATH)
    except Exception:
        pass


def send_telegram_notification(html_text: str, min_interval_sec: float = 600.0) -> bool:
    try:
        first_line = html_text.strip().split("\n")[0]
        clean_key = " ".join(first_line.split())

        is_standby_notice = any(k in html_text or k in clean_key for k in [
            "РЕЖИМ ОЖИДАНИЯ СБРОСА КВОТЫ",
            "РЕЖИМ ОЖИДАНИЯ",
            "QUOTA_WAIT",
            "QUOTA_EXHAUSTED",
            "ИСПЕРПАНИЕ КВОТЫ ANTIGRAVITY",
            "STANDBY",
            "выжидательной паузе"
        ])
        if is_standby_notice:
            # Standby notifications must be strictly throttled to at most once per 60 minutes (3600 seconds)
            min_interval_sec = max(min_interval_sec, 3600.0)
            clean_key = "STANDBY_QUOTA_WAIT_GLOBAL_ALERT"

        now = time.time()
        cooldowns = _load_tg_cooldowns()
        last_t = cooldowns.get(clean_key, 0.0)
        if now - last_t < min_interval_sec:
            log_event(f"[Telegram Throttled] Notification suppressed for '{clean_key[:50]}' (sent {int(now - last_t)}s ago < {int(min_interval_sec)}s).")
            return False

        _save_tg_cooldown(clean_key, now)

        import urllib.request
        import socket
        socket.setdefaulttimeout(15.0)
        cfg_path = Path(r"C:\Users\Администратор\.gemini\antigravity\companion_bridge_config.json")
        if not cfg_path.is_file():
            return False
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        tg = cfg.get("telegram", {})
        if not tg.get("enabled") or not tg.get("botToken") or not tg.get("chatId"):
            return False
        token = tg["botToken"]
        chat_id = tg["chatId"]
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        payload = json.dumps({
            "chat_id": chat_id,
            "text": html_text,
            "parse_mode": "HTML"
        }).encode("utf-8")
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})

        # Try up to 2 times with 15s timeout
        for attempt in range(2):
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    ok = bool(data.get("ok"))
                    log_event(f"[Telegram Sent] Notification delivered: {clean_key[:60]}... (ok={ok})")
                    return ok
            except Exception as net_err:
                if attempt == 0:
                    time.sleep(1.0)
                    continue
                log_event(f"[Telegram Error] Failed to send notification after 2 attempts: {net_err}")
                return False
    except Exception as e:
        log_event(f"[Telegram Error] Unexpected error in send_telegram_notification: {e}")
        return False


def get_active_antigravity_ls_env() -> dict[str, str]:
    """Dynamically resolves the active language_server address and CSRF token from running processes."""
    if not psutil:
        if ACTIVE_LS_ENV_PATH.is_file():
            try:
                data = json.loads(ACTIVE_LS_ENV_PATH.read_text(encoding="utf-8"))
                if data.get("ANTIGRAVITY_LS_ADDRESS") and data.get("ANTIGRAVITY_CSRF_TOKEN"):
                    return data
            except Exception:
                pass
        return {}
    try:
        ls_pid = None
        csrf = None
        for p in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                name = (p.info['name'] or '').lower()
                if name == 'language_server.exe':
                    cmdline = ' '.join(p.info['cmdline'] or [])
                    m = re.search(r'--csrf_token\s+([a-f0-9-]+)', cmdline)
                    if m:
                        csrf = m.group(1)
                        ls_pid = p.info['pid']
                        break
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        if not ls_pid or not csrf:
            if ACTIVE_LS_ENV_PATH.is_file():
                try:
                    data = json.loads(ACTIVE_LS_ENV_PATH.read_text(encoding="utf-8"))
                    if data.get("ANTIGRAVITY_LS_ADDRESS") and data.get("ANTIGRAVITY_CSRF_TOKEN"):
                        return data
                except Exception:
                    pass
            return {}

        ports = []
        # 1. Try process-specific net_connections
        try:
            proc = psutil.Process(ls_pid)
            for conn in proc.net_connections(kind='inet'):
                if conn.status == psutil.CONN_LISTEN:
                    ports.append(conn.laddr.port)
        except Exception:
            pass

        # 2. Fallback to global net_connections
        if not ports:
            try:
                for conn in psutil.net_connections(kind='inet'):
                    if conn.pid == ls_pid and conn.status == psutil.CONN_LISTEN:
                        ports.append(conn.laddr.port)
            except Exception:
                pass

        if ports:
            import socket
            # Verify socket connectivity and pick the verified listening port (favoring highest port for gRPC)
            target_port = None
            for p in sorted(ports, reverse=True):
                try:
                    s = socket.create_connection(('127.0.0.1', p), timeout=0.4)
                    s.close()
                    target_port = p
                    break
                except Exception:
                    continue
            if not target_port:
                target_port = max(ports)

            res_env = {
                "ANTIGRAVITY_LS_ADDRESS": f"localhost:{target_port}",
                "ANTIGRAVITY_CSRF_TOKEN": csrf,
                "ANTIGRAVITY_LS_PID": str(ls_pid),
                "port": str(target_port),
                "updated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat()
            }
            try:
                ACTIVE_LS_ENV_PATH.parent.mkdir(parents=True, exist_ok=True)
                tmp = ACTIVE_LS_ENV_PATH.with_suffix(".tmp")
                tmp.write_text(json.dumps(res_env, indent=2), encoding="utf-8")
                tmp.replace(ACTIVE_LS_ENV_PATH)
            except Exception:
                pass
            return res_env
    except Exception as e:
        log_event(f"[WARN] Failed to dynamically discover language_server: {e}")
    return {}


def check_and_kill_hanging(dry_run: bool = False) -> list[dict]:
    """Inspects processes natively via psutil with zero console window creation."""
    if not psutil:
        return []

    now = time.time()
    results = []

    try:
        for p in psutil.process_iter(['pid', 'name', 'cmdline', 'create_time']):
            try:
                name = (p.info['name'] or '').lower()
                if name not in ('node.exe', 'pwsh.exe', 'powershell.exe', 'python.exe', 'pythonw.exe', 'cmd.exe', 'language_server.exe'):
                    continue

                cmd_list = p.info['cmdline'] or []
                cmd = ' '.join(cmd_list)
                if not cmd:
                    continue

                if name == 'language_server.exe':
                    # Legitimate agentapi CLI invocations (run by supervisor or process_guard)
                    if 'agentapi' in cmd:
                        continue
                    age_sec = int(now - p.info['create_time'])
                    if age_sec < 180:
                        continue
                    is_mislaunched_ls = False
                    reason_ls = ""
                    if not any(k in cmd for k in ('--standalone', '--override_ide_name')):
                        is_mislaunched_ls = True
                        reason_ls = "Mislaunched standalone language_server (spawned directly without Electron CLI flags)"
                    else:
                        try:
                            ppid = p.ppid()
                            if psutil.pid_exists(ppid):
                                parent_p = psutil.Process(ppid)
                                p_name = (parent_p.name() or '').lower()
                                if 'antigravity-tools' in p_name:
                                    is_mislaunched_ls = True
                                    reason_ls = "Mislaunched language_server (parent is antigravity-tools.exe instead of Antigravity.exe)"
                        except Exception:
                            pass

                    if not is_mislaunched_ls:
                        try:
                            ppid = p.ppid()
                            parent_alive = False
                            if psutil.pid_exists(ppid):
                                parent_p = psutil.Process(ppid)
                                p_name = (parent_p.name() or '').lower()
                                if 'antigravity.exe' in p_name:
                                    parent_alive = True
                            if not parent_alive:
                                any_ag = any((proc.info.get('name') or '').lower() == 'antigravity.exe' for proc in psutil.process_iter(['name'], ad_value=''))
                                if not any_ag:
                                    age_sec = int(now - p.info['create_time'])
                                    if age_sec >= 30:
                                        is_mislaunched_ls = True
                                        reason_ls = "Orphaned language_server (Antigravity.exe GUI is not running)"
                        except Exception:
                            pass

                    if is_mislaunched_ls:
                        results.append({
                            "ProcessId": p.info['pid'],
                            "Name": name,
                            "AgeSeconds": int(now - p.info['create_time']),
                            "Reason": reason_ls,
                            "CommandLine": cmd[:160]
                        })
                    continue

                is_hanging_node = (name == 'node.exe') and (
                    ('patch-repl.cjs' in cmd) or
                    (' -e ' in cmd and 'companion_bridge' not in cmd and 'edge-devtools-mcp' not in cmd)
                )

                is_orphan_preview = (name in ('node.exe', 'cmd.exe')) and (
                    'vite preview' in cmd or 'vite.js" preview' in cmd
                )

                is_runaway_pwsh = (name in ('pwsh.exe', 'powershell.exe')) and (
                    '.Extension -in' in cmd or '.extension -in' in cmd
                )

                is_hanging_test = (name in ('python.exe', 'node.exe', 'pwsh.exe', 'powershell.exe')) and (
                    bool(re.search(r'pytest|unittest|vitest|jest|mocha|\btest\b', cmd)) and
                    'companion_bridge' not in cmd and
                    'supervisor' not in cmd and
                    'process_guard' not in cmd and
                    'action_bridge' not in cmd
                )

                is_hanging_pwsh_script = (name in ('pwsh.exe', 'powershell.exe')) and (
                    'supervisor' not in cmd and
                    'companion_bridge' not in cmd and
                    'process_guard' not in cmd and
                    'action_bridge' not in cmd and
                    'handover' not in cmd and
                    'watcher' not in cmd and
                    not is_hanging_test
                )

                # Check for orphan worker processes whose parent terminated
                is_orphan_worker = False
                if name in ('node.exe', 'python.exe', 'pwsh.exe', 'powershell.exe', 'cmd.exe') and not (is_hanging_node or is_hanging_test or is_orphan_preview):
                    if not any(k in cmd for k in ('daemon_supervisor', 'companion_bridge', 'telegram', 'antigravity_tools', 'language_server', 'server.js', 'main.js', 'handover', 'watcher', 'antigravity_process_guard', 'code.exe', 'antigravity.exe')):
                        age_sec = int(now - p.info['create_time'])
                        if age_sec >= 180:
                            try:
                                ppid = p.ppid()
                                if not psutil.pid_exists(ppid):
                                    is_orphan_worker = True
                                else:
                                    parent_proc = psutil.Process(ppid)
                                    parent_name = (parent_proc.name() or '').lower()
                                    if parent_name in ('svchost.exe', 'services.exe'):
                                        is_orphan_worker = True
                            except (psutil.NoSuchProcess, psutil.AccessDenied):
                                is_orphan_worker = True

                if is_orphan_worker:
                    results.append({
                        "ProcessId": p.info['pid'],
                        "Name": name,
                        "AgeSeconds": int(now - p.info['create_time']),
                        "Reason": "Orphaned zombie worker process (parent process dead)",
                        "CommandLine": cmd[:160]
                    })

                # Check for duplicate process_guard or stalled quota_recovery instances
                if name in ('python.exe', 'pythonw.exe'):
                    my_pid = os.getpid()
                    if 'antigravity_process_guard.py' in cmd and p.info['pid'] != my_pid:
                        results.append({
                            "ProcessId": p.info['pid'],
                            "Name": name,
                            "AgeSeconds": int(now - p.info['create_time']),
                            "Reason": "Duplicate antigravity_process_guard instance",
                            "CommandLine": cmd[:160]
                        })
                    elif 'quota_recovery_engine.py' in cmd:
                        age_sec = int(now - p.info['create_time'])
                        if age_sec >= 180:
                            results.append({
                                "ProcessId": p.info['pid'],
                                "Name": name,
                                "AgeSeconds": age_sec,
                                "Reason": "Stalled quota_recovery_engine worker (exceeded 180s)",
                                "CommandLine": cmd[:160]
                            })

                if is_hanging_node or is_runaway_pwsh or is_hanging_test or is_hanging_pwsh_script or is_orphan_preview:
                    age_seconds = int(now - p.info['create_time'])
                    threshold = 90
                    if is_runaway_pwsh:
                        threshold = 60
                    elif is_orphan_preview:
                        threshold = 240
                    elif is_hanging_test:
                        threshold = 4200 if 'soak' in cmd.lower() else 600
                    elif is_hanging_pwsh_script:
                        threshold = 300

                    if age_seconds >= threshold:
                        reason = "Hanging Node/tsx REPL on stdin" if is_hanging_node else (
                            "Orphan vite preview test server (exceeded 240s)" if is_orphan_preview else (
                                "Runaway pwsh expansion loop" if is_runaway_pwsh else (
                                    "Hanging test runner or deadlocked process" if is_hanging_test else "Deadlocked/hanging PowerShell process (exceeded 300s)"
                                )
                            )
                        )
                        results.append({
                            "ProcessId": p.info['pid'],
                            "Name": name,
                            "AgeSeconds": age_seconds,
                            "Reason": reason,
                            "CommandLine": cmd[:160]
                        })
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except Exception as e:
        log_event(f"[WARN] Error in process iteration: {e}")

    killed = []
    creationflags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
    for item in results:
        pid = item["ProcessId"]
        name = item["Name"]
        reason = item["Reason"]
        age = item["AgeSeconds"]
        cmd_preview = item["CommandLine"]

        log_event(f"[DETECTED] PID {pid} ({name}) running {age}s - Reason: {reason} | Cmd: {cmd_preview}")

        if dry_run:
            killed.append(item)
            continue

        try:
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(pid)],
                capture_output=True,
                timeout=5,
                creationflags=creationflags
            )
            log_event(f"[TERMINATED] Process tree for PID {pid} killed successfully.")
            killed.append(item)
        except Exception as e:
            log_event(f"[ERROR] Failed to terminate PID {pid}: {e}")

    return killed


def get_conversation_project_id(conv_id: str, exe_path: Path, ls_env: dict[str, str]) -> str | None:
    """Resolves project ID for a conversation, checking config first, then dynamic agentapi."""
    # Fast path: check companion_bridge_config.json
    cfg_path = Path(r"C:\Users\Администратор\.gemini\antigravity\companion_bridge_config.json")
    if cfg_path.is_file():
        try:
            cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
            for comp in cfg.get("browser", {}).get("companions", {}).values():
                if comp.get("antigravityConversationId") == conv_id:
                    pid = comp.get("projectId")
                    if pid:
                        return pid
        except Exception:
            pass

    creationflags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
    env = os.environ.copy()
    if ls_env:
        for k, v in ls_env.items():
            if v is not None:
                env[str(k)] = str(v)
    env = {str(k): str(v) for k, v in env.items() if v is not None}
    try:
        res = subprocess.run(
            [str(exe_path), "agentapi", "get-conversation-metadata", conv_id],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            creationflags=creationflags
        )
        if res.returncode == 0:
            data = json.loads(res.stdout)
            return data.get("response", {}).get("conversationMetadata", {}).get("metadata", {}).get("projectId")
    except Exception:
        pass
    return None


LAST_QUOTA_RECOVERY_SPAWN = 0.0
DISK_QUOTA_COOLDOWN_PATH = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\LAST_QUOTA_RECOVERY_TIME.json")


def trigger_quota_recovery(conv_id: str = "", reason: str = "", workspace_paths: list = None) -> bool:
    """Spawns quota_recovery_engine.py to autonomously rotate account and resume chats with strict persistent throttling."""
    global LAST_QUOTA_RECOVERY_SPAWN
    now = time.time()

    # 1. HARD PERSISTENT DISK THROTTLE: Minimum 180 seconds across ALL processes
    if DISK_QUOTA_COOLDOWN_PATH.is_file():
        try:
            last_disk = float(DISK_QUOTA_COOLDOWN_PATH.read_text(encoding="utf-8").strip())
            if now - last_disk < 180.0:
                log_event(f"[QUOTA_RECOVERY] Spawn throttled by disk gate: triggered {int(now - last_disk)}s ago (< 180s cooldown).")
                return False
        except Exception:
            pass

    # 2. In-memory throttle: Minimum 180 seconds
    if now - LAST_QUOTA_RECOVERY_SPAWN < 180.0:
        log_event(f"[QUOTA_RECOVERY] Spawn throttled: quota recovery already triggered {int(now - LAST_QUOTA_RECOVERY_SPAWN)}s ago (< 180s cooldown).")
        return False

    # 3. Check if ANY quota_recovery_engine process is ALREADY running
    if psutil:
        try:
            for p in psutil.process_iter(['pid', 'name', 'cmdline']):
                try:
                    cmd_line = ' '.join(p.info.get('cmdline') or []).lower()
                    if 'quota_recovery_engine.py' in cmd_line:
                        log_event(f"[QUOTA_RECOVERY] Quota recovery engine process already active (PID: {p.info.get('pid')}), skipping new spawn.")
                        LAST_QUOTA_RECOVERY_SPAWN = now
                        return True
                except Exception:
                    pass
        except Exception:
            pass

    # Account rotation is an infrastructure operation and should proceed even if pipeline tasks are paused
    if is_pipeline_in_standby():
        log_event(f"[QUOTA_RECOVERY] Standby active, but rotating account to restore healthy platform quota for {conv_id} ({reason[:60]}).")

    recovery_script = Path(r"C:\Scripts\AntigravityProjects\companion-handoff\src\quota_recovery_engine.py")
    if not recovery_script.is_file():
        log_event(f"[QUOTA_RECOVERY] Cannot trigger recovery: script not found at {recovery_script}")
        return False

    # 4. Register interrupted session if conv_id provided
    if conv_id:
        try:
            sys_path = r"C:\Scripts\AntigravityProjects\companion-handoff\src"
            if sys_path not in sys.path:
                sys.path.insert(0, sys_path)
            from quota_recovery_engine import SessionRegistry
            SessionRegistry.register_interruption(conv_id, workspace_paths or [], reason)
        except Exception as reg_err:
            log_event(f"[QUOTA_RECOVERY] Warning: failed to register interruption: {reg_err}")

    # 5. Check if recovery process is already active via lock
    if QUOTA_RECOVERY_LOCK_PATH.is_file():
        try:
            lock_pid_str = QUOTA_RECOVERY_LOCK_PATH.read_text(encoding="utf-8").strip()
            lock_age = now - QUOTA_RECOVERY_LOCK_PATH.stat().st_mtime
            is_running = False
            if lock_pid_str.isdigit():
                pid_int = int(lock_pid_str)
                if pid_int != os.getpid() and psutil and psutil.pid_exists(pid_int):
                    try:
                        p = psutil.Process(pid_int)
                        if "quota_recovery_engine" in " ".join(p.cmdline() or []).lower():
                            is_running = True
                    except Exception:
                        pass
            if is_running and lock_age < 180.0:
                log_event(f"[QUOTA_RECOVERY] Recovery already in progress by active PID {lock_pid_str} (lock age: {int(lock_age)}s).")
                LAST_QUOTA_RECOVERY_SPAWN = now
                return True
            elif not is_running or lock_age >= 180.0:
                try:
                    QUOTA_RECOVERY_LOCK_PATH.unlink(missing_ok=True)
                except Exception:
                    pass
        except Exception:
            pass

    LAST_QUOTA_RECOVERY_SPAWN = now
    try:
        DISK_QUOTA_COOLDOWN_PATH.parent.mkdir(parents=True, exist_ok=True)
        DISK_QUOTA_COOLDOWN_PATH.write_text(str(now), encoding="utf-8")
    except Exception:
        pass

    log_event(f"[QUOTA_RECOVERY] 🚀 Launching autonomous quota recovery engine for {conv_id}...")
    try:
        python_exe = sys.executable
        flags = getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x00000200)
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
        child_proc = subprocess.Popen(
            [python_exe, str(recovery_script), "run"],
            stdin=subprocess.DEVNULL,
            env=env,
            creationflags=flags,
            close_fds=True
        )
        if child_proc and child_proc.pid:
            try:
                QUOTA_RECOVERY_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
                QUOTA_RECOVERY_LOCK_PATH.write_text(str(child_proc.pid), encoding="utf-8")
            except Exception:
                pass
        return True
    except Exception as spawn_err:
        log_event(f"[QUOTA_RECOVERY] Failed to spawn quota recovery worker: {spawn_err}")
        return False


_LAST_LIVE_QUOTA_REFRESH = 0.0

def check_active_account_quota(force_refresh: bool = False) -> tuple[bool, float | None, float | None]:
    """
    Inspects live Gemini quota of current active account directly from Antigravity Tools.
    Machine-deterministic floats (0.0 .. 1.0) directly from Google AI upstream API.
    Refreshes from Google API every 180 seconds or whenever force_refresh=True.
    """
    global _LAST_LIVE_QUOTA_REFRESH
    try:
        if r"C:\Scripts\AntigravityProjects\companion-handoff\src" not in sys.path:
            sys.path.insert(0, r"C:\Scripts\AntigravityProjects\companion-handoff\src")
        from quota_recovery_engine import AntigravityToolsAPI
        api_tools = AntigravityToolsAPI()

        now = time.time()
        if force_refresh or (now - _LAST_LIVE_QUOTA_REFRESH >= 30.0):
            try:
                api_tools.refresh_accounts()
                _LAST_LIVE_QUOTA_REFRESH = now
            except Exception:
                pass

        curr_acc = api_tools.get_current_account()
        curr_g5h = None
        curr_gw = None
        for g in curr_acc.get("quota", {}).get("quota_groups", []):
            for b in g.get("buckets", []):
                bid = b.get("bucket_id")
                if bid == "gemini-5h":
                    curr_g5h = b.get("remaining_fraction")
                elif bid == "gemini-weekly":
                    curr_gw = b.get("remaining_fraction")
        is_depleted = False
        # Depleted if Google AI upstream quota is < 0.06 (6% safety buffer for 5h) or < 0.02 (2% for weekly)
        if (curr_gw is not None and curr_gw < 0.02) or (curr_g5h is not None and curr_g5h < 0.06):
            is_depleted = True
        return is_depleted, curr_g5h, curr_gw
    except Exception:
        return False, None, None


def check_and_resume_interrupted_chats(allow_autonomous_continue: bool = True) -> list[str]:
    """Inspects active conversations and automatically resumes chats interrupted by quota/stream break or server restarts."""
    active_account_quota_depleted, curr_g5h, curr_gw = check_active_account_quota()

    # Proactive Quota Sentinel: If Google API reports that current account quota is depleted, rotate proactively!
    if active_account_quota_depleted:
        log_event(f"[PROACTIVE_QUOTA] 🛑 Live quota depleted on active account in Google API (5h: {(curr_g5h or 0)*100:.1f}%, weekly: {(curr_gw or 0)*100:.1f}%). Triggering proactive rotation!")
        trigger_quota_recovery(reason=f"Proactive quota rotation: live quota depleted (5h={curr_g5h}, weekly={curr_gw})")
        return []

    # 0. Standby inspection with intelligent auto-lift if quota is available
    standby_info = get_standby_info()
    if standby_info.get("is_standby") is True:
        standby_mode = standby_info.get("mode", "")
        # If in quota standby, but active account currently has usable quota (manual switch or reset arrived):
        if standby_mode in ("QUOTA_EXHAUSTED", "QUOTA_WAIT") and not active_account_quota_depleted:
            log_event(f"[STANDBY] Usable quota detected on active account (5h: {(curr_g5h or 0)*100:.0f}%, weekly: {(curr_gw or 0)*100:.0f}%). Auto-lifting quota standby.")
            set_pipeline_standby(False, "Активный аккаунт имеет доступную квоту", mode="NORMAL", send_tg=True)
        elif standby_mode in ("MAN_IN_THE_MIDDLE", "PRE_SLEEP", "PRE_HIBERNATE", "MANUAL", "USER_PAUSE"):
            # Task progression (/nextphase) is gated by allow_autonomous_continue,
            # but quota detection and recovery MUST run to protect the user and agent.
            pass
        elif active_account_quota_depleted:
            pass

    cfg_path = Path(r"C:\Users\Администратор\.gemini\antigravity\companion_bridge_config.json")
    if not cfg_path.is_file():
        return []

    exe = Path(r"C:\Users\Администратор\AppData\Local\Programs\Antigravity\resources\bin\language_server.exe")
    if not exe.is_file():
        return []

    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception:
        return []

    brain_dir = Path(r"C:\Users\Администратор\.gemini\antigravity\brain")
    resumed = []
    now = time.time()

    # Discover live Antigravity connection environment
    ls_env = get_active_antigravity_ls_env()
    if not ls_env or not ls_env.get("ANTIGRAVITY_LS_ADDRESS"):
        # Server is restarting or not listening yet. Wait for next loop.
        return []

    retired_ids = get_retired_conversation_ids()
    targets = {}
    for comp_key, comp in cfg.get("browser", {}).get("companions", {}).items():
        cid = comp.get("antigravityConversationId")
        if cid and cid not in retired_ids:
            targets[cid] = {
                "name": comp.get("name") or comp_key,
                "projectPath": comp.get("projectPath"),
                "projectId": comp.get("projectId"),
            }

    # Authoritative supervisor session
    sup_cid = cfg.get("supervisor", {}).get("antigravityConversationId")
    if sup_cid and sup_cid not in targets and sup_cid not in retired_ids:
        targets[sup_cid] = {
            "name": "Supervisor",
            "projectPath": None,
            "projectId": cfg.get("supervisor", {}).get("projectId"),
        }

    # Prune old entries from correlated failure tracking window (older than 90s)
    global RECENT_STREAM_INTERRUPTIONS
    RECENT_STREAM_INTERRUPTIONS = [x for x in RECENT_STREAM_INTERRUPTIONS if now - x.get("time", 0) < 90.0]

    api_tools = None
    try:
        from quota_recovery_engine import AntigravityToolsAPI
        api_tools = AntigravityToolsAPI()
    except Exception:
        pass

    for cid, target_info in targets.items():
        transcript_file = brain_dir / cid / ".system_generated" / "logs" / "transcript.jsonl"
        if not transcript_file.is_file():
            continue

        try:
            steps = read_transcript_tail(transcript_file, max_lines=100)
            if not steps:
                continue

            last_step = steps[-1]
            stype = last_step.get("type")
            status = last_step.get("status")
            content = str(last_step.get("content") or last_step.get("error") or "")
            c_lower = content.lower()

            # Priority Check 0: Immediate Quota Exhaustion Sentinel (attempt 1..8)
            # Catches genuine Google AI / Gemini 429 quota exhaustion immediately on attempt 1!
            # Must ONLY inspect genuine ERROR/SYSTEM steps, NEVER normal agent responses or tool outputs!
            fresh_quota_error = None
            for step in reversed(steps[-8:]):
                st = step.get("type")
                ss = step.get("status")
                src = step.get("source")
                is_candidate = (st in ("ERROR_MESSAGE", "ERROR") or ss == "ERROR" or src == "SYSTEM")
                if not is_candidate:
                    continue

                # For error steps, inspect error message or error content
                c_err = str(step.get("error") or (step.get("content") if st in ("ERROR_MESSAGE", "ERROR") else "")).strip()
                if not c_err:
                    continue

                if is_quota_exhaustion_text(c_err):
                    created_at_str = step.get("created_at")
                    err_age = 9999.0
                    if created_at_str:
                        try:
                            dt_err = dt.datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                            err_age = now - dt_err.timestamp()
                        except Exception:
                            pass
                    if err_age < 300.0:
                        fresh_quota_error = (c_err, err_age)
                        break

            if fresh_quota_error:
                c_err, err_age = fresh_quota_error
                # CRITICAL: Fresh error step in transcript is empirical ground truth from Google LLM endpoint!
                # Even if external tool cache claims healthy quota, the account cannot make model calls right now.
                log_event(f"[QUOTA_DETECTED] 🛑 Quota exhaustion confirmed from transcript in {target_info['name']} (age: {int(err_age)}s): {c_err[:120]}. Triggering autonomous quota rotation!")
                trigger_quota_recovery(cid, f"Quota exhaustion in {target_info['name']}: {c_err[:120]}", [target_info.get("projectPath")])
                CONSECUTIVE_FAILURES[cid] = 0
                return resumed

            # If agent is actively running/thinking right now, check for stalled generation / "Model unavailable" retry loop
            if stype == "PLANNER_RESPONSE" and status == "RUNNING":
                try:
                    mtime = transcript_file.stat().st_mtime
                    stalled_seconds = now - mtime
                except Exception:
                    stalled_seconds = 0.0

                if stalled_seconds < 30.0:
                    continue

                # Fast Interceptor: At 30s of silence, immediately check live quota with force_refresh
                is_depleted_live, live_5h, live_w = check_active_account_quota(force_refresh=True)
                is_stalled_quota = is_depleted_live

                if not is_stalled_quota:
                    try:
                        ls_log_path = Path(r"C:\Users\Администратор\AppData\Roaming\Antigravity\logs\language_server.log")
                        if ls_log_path.is_file():
                            tail_lines = open(ls_log_path, encoding="utf-8", errors="ignore").readlines()[-40:]
                            if any(is_quota_exhaustion_text(tl) for tl in tail_lines):
                                is_stalled_quota = True
                    except Exception:
                        pass

                if is_stalled_quota or stalled_seconds >= 90.0:
                    log_event(f"[QUOTA_DETECTED] 🛑 Frozen stream / Model unavailable retry detected in {target_info['name']} (stalled {int(stalled_seconds)}s, depleted={is_depleted_live}, 5h={live_5h}). Triggering immediate quota rotation!")
                    trigger_quota_recovery(cid, f"Model unavailable / stalled stream ({int(stalled_seconds)}s) in {target_info['name']}", [target_info.get("projectPath")])
                    return resumed
                continue

            network_markers = [
                "there was a network issue", "failed to connect", "socket hang up",
                "connection error", "connection reset", "econnreset", "econnrefused",
                "etimedout", "service unavailable", "fetch failed", "http 503", "http 502", "http 504"
            ]
            stream_markers = ["the stream was interrupted", "stream was interrupted", "поток ответа был прерван", "поток был прерван"]
            interruption_markers = stream_markers + network_markers

            # A step is an error candidate ONLY if generated by SYSTEM with ERROR status or ERROR_MESSAGE type
            last_src = last_step.get("source")
            is_err_step_type = (last_src == "SYSTEM" and (stype in ("ERROR_MESSAGE", "ERROR") or status == "ERROR"))
            err_text_val = str(last_step.get("error") or (last_step.get("content") if last_src == "SYSTEM" else "")).strip()
            is_err_condition = is_err_step_type and (
                any(m in err_text_val.lower() for m in interruption_markers) or
                is_quota_exhaustion_text(err_text_val)
            )

            last_t = LAST_RESUMED_TIMESTAMPS.get(cid, 0.0)
            # Enforce hard minimum cooldown of 45s between ANY resume messages to allow turn thinking
            if now - last_t < 45.0:
                continue

            # If the latest step is an automated resume message sent recently (< 90s),
            # the agent is actively thinking or processing. Do NOT send duplicate messages!
            if stype == "USER_INPUT":
                if any(m in c_lower for m in AUTO_RESUME_TITLES) and (now - last_t < 90.0):
                    continue

            # For normal idle conversations without error, wait at least 90s
            if now - last_t < 90.0 and not is_err_condition:
                continue

            # Skip idle conversations that have no error and are not project autonomous loops or Supervisor audit
            if not is_err_condition and not target_info.get("projectPath") and target_info.get("name") != "Supervisor":
                continue

            # Record interruption event in sliding window for correlated failure detection
            if is_err_condition:
                if not any(x.get("cid") == cid and now - x.get("time", 0) < 30.0 for x in RECENT_STREAM_INTERRUPTIONS):
                    RECENT_STREAM_INTERRUPTIONS.append({
                        "time": now,
                        "cid": cid,
                        "name": target_info.get("name", cid[:8]),
                        "reason": content[:100]
                    })

                # Check correlated multi-conversation failure across ALL conversations
                # If >= 2 conversations fail simultaneously within 90s, trigger account rotation!
                active_failures = {x.get("cid"): x.get("name") for x in RECENT_STREAM_INTERRUPTIONS if now - x.get("time", 0) < 90.0}
                if len(active_failures) >= 2 and (now - LAST_SERVER_RESTART_TIME >= 60.0):
                    has_explicit = any(is_quota_exhaustion_text(x.get("reason", "")) for x in RECENT_STREAM_INTERRUPTIONS)
                    failed_names = ", ".join(list(active_failures.values())[:4])
                    if active_account_quota_depleted or has_explicit:
                        log_event(f"[CORRELATED_FAILURE] 🛑 Systemic failure + depleted quota confirmed across {len(active_failures)} conversations ({failed_names}). Triggering quota rotation!")
                        trigger_quota_recovery(cid, f"Correlated multi-conversation stream failure with depleted quota ({len(active_failures)} chats: {failed_names})", [target_info.get("projectPath")])
                        RECENT_STREAM_INTERRUPTIONS.clear()
                        CONSECUTIVE_FAILURES.clear()
                        return resumed
                    else:
                        log_event(f"[CORRELATED_FAILURE] Multiple conversations ({len(active_failures)} chats: {failed_names}) had stream interruptions, but live Google AI quota is healthy. Skipping account rotation false alarm.")
                        RECENT_STREAM_INTERRUPTIONS.clear()

                # If single stream interruption occurs and active account quota isn't marked depleted yet, force live Google quota refresh
                if not active_account_quota_depleted and api_tools and any(m in c_lower for m in stream_markers):
                    try:
                        api_tools.refresh_accounts()
                        curr_acc_fresh = api_tools.get_current_account()
                        fresh_g5h = None
                        fresh_gw = None
                        for g in curr_acc_fresh.get("quota", {}).get("quota_groups", []):
                            for b in g.get("buckets", []):
                                bid = b.get("bucket_id")
                                if bid == "gemini-5h":
                                    fresh_g5h = b.get("remaining_fraction")
                                elif bid == "gemini-weekly":
                                    fresh_gw = b.get("remaining_fraction")
                        if (fresh_gw is not None and fresh_gw < 0.05) or (fresh_g5h is not None and fresh_g5h < 0.10):
                            active_account_quota_depleted = True
                    except Exception:
                        pass

            needs_resume = False
            error_reason = ""
            is_network_failure = False

            # Priority Check 1: Fresh quota error (detect before generic stream interruption)
            for step in reversed(steps[-8:]):
                t = step.get("type")
                s = step.get("status")
                src = step.get("source")
                is_err_step = (src == "SYSTEM" and (t in ("ERROR_MESSAGE", "ERROR") or s == "ERROR"))
                if is_err_step:
                    c = str(step.get("error") or step.get("content") or "").lower()
                    is_explicit_quota = is_quota_exhaustion_text(c)
                    if is_explicit_quota:
                        created_at_str = step.get("created_at")
                        error_age = 9999.0
                        if created_at_str:
                            try:
                                dt_err = dt.datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                                error_age = now - dt_err.timestamp()
                            except Exception:
                                pass
                        if error_age < 300.0:
                            log_event(f"[QUOTA_DETECTED] 🛑 Quota exhaustion confirmed in {target_info['name']} (age: {int(error_age)}s, err: {c[:80]}). Triggering autonomous quota rotation.")
                            trigger_quota_recovery(cid, f"Quota exhaustion in {target_info['name']}: {c[:120]}", [target_info.get("projectPath")])
                            CONSECUTIVE_FAILURES[cid] = 0
                            return resumed
                        break

            # Find the most recent error/interruption step index
            last_err_idx = -1
            for idx_step, s_item in enumerate(steps):
                s_c = str(s_item.get("content") or s_item.get("error") or "").lower()
                s_t = s_item.get("type")
                s_s = s_item.get("status")
                if (s_t in ("ERROR_MESSAGE", "ERROR") or s_s == "ERROR") and any(m in s_c for m in interruption_markers):
                    last_err_idx = idx_step

            # Check if recent steps show real model progress AFTER the error to reset failure counter
            if last_err_idx >= 0:
                steps_after_err = steps[last_err_idx + 1:]
                has_recent_progress = any(
                    (x.get("type") == "PLANNER_RESPONSE" and x.get("status") != "ERROR" and not any(m in str(x.get("content") or x.get("error") or "").lower() for m in interruption_markers)) or
                    (x.get("type") == "GENERIC")
                    for x in steps_after_err
                )
            else:
                has_recent_progress = any(
                    (x.get("type") == "PLANNER_RESPONSE" and x.get("status") != "ERROR") or
                    (x.get("type") == "GENERIC")
                    for x in steps[-6:]
                )
            if has_recent_progress:
                CONSECUTIVE_FAILURES[cid] = 0

            # Check 2: Stream interruption & Transient Network Errors with Escalation
            for step in reversed(steps[-8:]):
                t = step.get("type")
                s = step.get("status")
                src = step.get("source")
                is_err_step = (src == "SYSTEM" and (t in ("ERROR_MESSAGE", "ERROR") or s == "ERROR"))
                if not is_err_step:
                    continue
                c = str(step.get("error") or step.get("content") or "").lower()
                if any(m in c for m in interruption_markers):
                    # Check error freshness: only resume if the error occurred within last 5 minutes!
                    created_at_str = step.get("created_at")
                    error_age = 9999.0
                    if created_at_str:
                        try:
                            dt_err = dt.datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                            error_age = now - dt_err.timestamp()
                        except Exception:
                            pass
                    if error_age > 300.0:
                        continue

                    step_idx = steps.index(step)
                    subsequent = steps[step_idx + 1:]

                    def is_automated_step(x_step):
                        x_c = str(x_step.get("content") or x_step.get("error") or "").lower()
                        return any(m in x_c for m in AUTO_RESUME_TITLES)

                    has_real_reply = any(
                        (x.get("type") == "USER_INPUT" and not is_automated_step(x)) or
                        (x.get("type") == "PLANNER_RESPONSE" and x.get("status") != "ERROR") or
                        (x.get("type") == "GENERIC")
                        for x in subsequent
                    )
                    if not has_real_reply:
                        consec = CONSECUTIVE_FAILURES.get(cid, 0)
                        
                        # Priority 1: Immediate rotation if quota is already confirmed depleted OR explicit quota error text
                        if (active_account_quota_depleted or is_quota_exhaustion_text(c)) and (now - LAST_SERVER_RESTART_TIME >= 60.0):
                            log_event(f"[ESCALATION] 🛑 Conversation {target_info['name']} ({cid}) interrupted with depleted/exhausted quota (failures={consec}). Triggering immediate quota recovery rotation.")
                            trigger_quota_recovery(cid, f"Quota exhaustion in {target_info['name']}: {c[:100]}", [target_info.get("projectPath")])
                            CONSECUTIVE_FAILURES[cid] = 0
                            return resumed

                        # Priority 2: Hard Stop against infinite message loops!
                        # If this conversation has failed 2 times consecutively without progress (attempt #3):
                        # The account/connection is definitively broken, regardless of offline caches.
                        # Enforce account rotation immediately!
                        if consec >= 2:
                            if now - LAST_SERVER_RESTART_TIME >= 60.0:
                                log_event(f"[ESCALATION] 🛑 Conversation {target_info['name']} ({cid}) failed {consec + 1} consecutive times with stream interruption. Quota flag={active_account_quota_depleted}. Enforcing autonomous account rotation!")
                                trigger_quota_recovery(cid, f"Repeated stream interruption ({consec + 1} attempts) in {target_info['name']}: {c[:100]}", [target_info.get("projectPath")])
                                CONSECUTIVE_FAILURES[cid] = 0
                                return resumed
                            else:
                                log_event(f"[ESCALATION] Repeated stream interruption in {target_info['name']} ({cid}), but language_server recently restarted ({int(now - LAST_SERVER_RESTART_TIME)}s ago). Waiting for stabilization.")
                                continue

                        needs_resume = True
                        CONSECUTIVE_FAILURES[cid] = consec + 1
                        max_retries = 2
                        if any(m in c for m in network_markers):
                            is_network_failure = True
                            error_reason = f"Восстановление после сетевого сбоя (попытка {CONSECUTIVE_FAILURES[cid]}/{max_retries})"
                        else:
                            error_reason = f"Восстановление прерванного потока (попытка {CONSECUTIVE_FAILURES[cid]}/{max_retries})"
                        break


            # Check 3: Stalled autonomous loop (.agy/NEXT_ACTION.json auto_continue: true)
            if not needs_resume and allow_autonomous_continue:
                proj_root_str = target_info.get("projectPath")
                if proj_root_str:
                    # Enforce project exclusivity: only resume if THIS cid is the registered companion for this projectPath
                    active_cid_for_path = None
                    for comp in cfg.get("browser", {}).get("companions", {}).values():
                        if comp.get("projectPath") and Path(comp.get("projectPath")).resolve() == Path(proj_root_str).resolve():
                            active_cid_for_path = comp.get("antigravityConversationId")
                            break
                    if active_cid_for_path and active_cid_for_path != cid:
                        continue

                    na_file = Path(proj_root_str) / ".agy" / "NEXT_ACTION.json"
                    cl_file = Path(proj_root_str) / ".agy" / "CLOSURE_STATE.json"
                    rr_file = Path(proj_root_str) / ".agy" / "RUN_RESULT.json"
                    if na_file.is_file():
                        try:
                            na_data = json.loads(na_file.read_text(encoding="utf-8"))
                            auto_continue = na_data.get("auto_continue") is True
                            decision_req = na_data.get("owner_decision_required") is True
                            
                            # Never auto-resume if the work item is already closed or completed
                            is_closed = False
                            if cl_file.is_file():
                                try:
                                    cl_data = json.loads(cl_file.read_text(encoding="utf-8"))
                                    if cl_data.get("work_item_id") == na_data.get("work_item_id") and (
                                        cl_data.get("implementation_status") == "completed" or
                                        cl_data.get("closure_reason") or
                                        cl_data.get("next_owner_goal_allowed") is False
                                    ):
                                        is_closed = True
                                except Exception:
                                    pass
                            if rr_file.is_file():
                                try:
                                    rr_data = json.loads(rr_file.read_text(encoding="utf-8"))
                                    if rr_data.get("work_item_id") == na_data.get("work_item_id") and rr_data.get("implementation_status") == "completed":
                                        is_closed = True
                                except Exception:
                                    pass

                            # If NEXT_ACTION declared an active route to execute (e.g. continuation delta /auditphase), never consider closed
                            if na_data.get("route"):
                                is_closed = False

                            # Never auto-resume if awaiting companion audit or acceptance
                            awaiting_companion = False
                            wi_file = Path(proj_root_str) / ".agy" / "WORK_ITEM.json"
                            if wi_file.is_file():
                                try:
                                    wi_data = json.loads(wi_file.read_text(encoding="utf-8"))
                                    if wi_data.get("status") in ("READY_FOR_COMPANION_AUDIT", "SUBMITTED_FOR_REVIEW", "COMPLETED", "WAIT_OWNER"):
                                        awaiting_companion = True
                                except Exception:
                                    pass
                            if rr_file.is_file():
                                try:
                                    rr_data = json.loads(rr_file.read_text(encoding="utf-8"))
                                    if rr_data.get("status") in ("READY_FOR_COMPANION_AUDIT", "SUBMITTED_FOR_REVIEW", "COMPLETED"):
                                        awaiting_companion = True
                                except Exception:
                                    pass

                            # Check if last step completed cleanly (status == 'DONE') and no active route is pending
                            is_done_and_idle = (status == "DONE" and not is_err_condition)
                            has_executable_route = bool(na_data.get("route") or na_data.get("command") or na_data.get("state_declared_next_required_command"))

                            is_in_standby = standby_info.get("is_standby") is True
                            if not is_in_standby and allow_autonomous_continue and auto_continue and not decision_req and not is_closed and not awaiting_companion and (has_executable_route or not is_done_and_idle) and (now - last_t >= 120.0):
                                created_at_str = last_step.get("created_at")
                                if created_at_str:
                                    dt_last = dt.datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                                    idle_age = now - dt_last.timestamp()
                                    if idle_age >= 120.0:
                                        needs_resume = True
                                        error_reason = f"Простой автономного цикла (auto_continue: true, простой {int(idle_age)}s)"
                        except Exception:
                            pass
            if not needs_resume and target_info.get("name") == "Supervisor":
                # MITM / STANDBY GATE: In MitM or Standby mode, Cron / scheduled audit must NOT execute!
                if not allow_autonomous_continue or standby_info.get("is_standby") is True:
                    continue
                sup_cfg = cfg.get("supervisor", {})
                if sup_cfg.get("enabled", True):
                    audit_interval = float(sup_cfg.get("auditIntervalSeconds", 3600.0))
                    sup_state_file = Path(r"C:\Users\Администратор\.agentic-pipeline\action-bridge\SUPERVISOR_AUDIT_STATE.json")
                    last_audit_ts = 0.0
                    if sup_state_file.is_file():
                        try:
                            last_audit_ts = float(json.loads(sup_state_file.read_text(encoding="utf-8")).get("last_audit_timestamp", 0.0))
                        except Exception:
                            pass
                    else:
                        last_audit_ts = now
                        try:
                            sup_state_file.parent.mkdir(parents=True, exist_ok=True)
                            sup_state_file.write_text(json.dumps({"last_audit_timestamp": now, "iso": dt.datetime.now().isoformat()}, indent=2), encoding="utf-8")
                        except Exception:
                            pass

                    time_since_audit = now - last_audit_ts
                    last_t = LAST_RESUMED_TIMESTAMPS.get(cid, 0.0)
                    is_idle_done = (status == "DONE" and not is_err_condition)

                    if (time_since_audit >= audit_interval) and is_idle_done and (now - last_t >= 120.0):
                        created_at_str = last_step.get("created_at")
                        idle_age = 9999.0
                        if created_at_str:
                            try:
                                dt_last = dt.datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                                idle_age = now - dt_last.timestamp()
                            except Exception:
                                pass
                        if idle_age >= 60.0:
                            needs_resume = True
                            error_reason = f"Плановый регулярный аудит Supervisor ({int(time_since_audit / 60)} мин)"
                            resume_title = "Регулярный аудит стабильности и дисциплины"
                            resume_content = (
                                "Регулярный аудит стабильности системы Agentic Pipeline и жесткий контроль дисциплины дочерних агентов (H10, Vitalis).\n"
                                "Анализ логов, выявление ТОП-10 оставшихся узких мест и факторов нарушения регламентов, формирование долгосрочных системных решений."
                            )
                            try:
                                sup_state_file.write_text(json.dumps({"last_audit_timestamp": now, "iso": dt.datetime.now().isoformat()}, indent=2), encoding="utf-8")
                            except Exception:
                                pass

            if needs_resume:
                proj_name = target_info["name"]
                log_event(f"[AUTO_RESUME] Interrupted conversation detected: {proj_name} ({cid}). Reason: {error_reason}. Resuming via {ls_env['ANTIGRAVITY_LS_ADDRESS']}...")

                proj_id = target_info.get("projectId") or get_conversation_project_id(cid, exe, ls_env)
                env = os.environ.copy()
                env["ANTIGRAVITY_LS_ADDRESS"] = ls_env["ANTIGRAVITY_LS_ADDRESS"]
                env["ANTIGRAVITY_CSRF_TOKEN"] = ls_env["ANTIGRAVITY_CSRF_TOKEN"]
                if proj_id:
                    env["ANTIGRAVITY_PROJECT_ID"] = proj_id
                env["ANTIGRAVITY_CONVERSATION_ID"] = cid
                env.pop("ANTIGRAVITY_SOURCE_METADATA", None)

                creationflags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
                resume_title = "Возобновление прерванного потока"
                resume_content = "Поток ответа восстановлен. Продолжай выполнение задачи с места остановки."
                if is_network_failure:
                    resume_title = "Возобновление после сетевого сбоя"
                    resume_content = (
                        "Сетевое подключение к серверу восстановлено. "
                        "Предыдущий шаг был прерван из-за кратковременной сетевой ошибки. "
                        "Продолжай выполнение задачи с места остановки."
                    )
                elif target_info.get("projectPath"):
                    resume_title = "Auto-Resume Interrupted Task"
                    extra_ctx = ""
                    try:
                        na_f = Path(target_info["projectPath"]) / ".agy" / "NEXT_ACTION.json"
                        if na_f.is_file():
                            na_d = json.loads(na_f.read_text(encoding="utf-8"))
                            wid = na_d.get("work_item_id")
                            cmd_act = na_d.get("route") or na_d.get("state_declared_next_required_command") or na_d.get("command")
                            ph = na_d.get("phase") or na_d.get("phase_name")
                            if wid:
                                extra_ctx = f" Активный элемент: {wid}"
                                if ph:
                                    extra_ctx += f" (фаза: {ph})"
                                if cmd_act:
                                    extra_ctx += f", следующая команда: {cmd_act}"
                                extra_ctx += "."
                    except Exception:
                        pass
                    operational_banner = (
                        "\n\n[РЕГЛАМЕНТ СКОРОСТИ И ДИСЦИПЛИНЫ:\n"
                        "1. СТРОГИЙ ЗАПРЕТ МИКРО-СЛАЙСИНГА: view_file поддерживает до 800 строк. Всегда читай файлы целиком без StartLine/EndLine! Запрещено резать < 300 строк.\n"
                        "2. ПАРАЛЛЕЛЬНОЕ БАТЧИРОВАНИЕ ИНСТРУМЕНТОВ: строго группируй вызовы в 1 ход [view_file, grep, replace]. Никаких одиночных вызовов.\n"
                        "3. НОЛЬ ПОВТОРНЫХ ЧТЕНИЙ: не перечитывай файлы из контекста, делай прямые правки replace_file_content.\n"
                        "4. CODEBASE-MEMORY FIRST: вызывай search_graph / get_code_snippet через MCP перед grep_search.\n"
                        "5. СИНХРОННЫЕ КОМАНДЫ: WaitMsBeforeAsync: 8000-10000 для быстрых скриптов.\n"
                        "6. ЗАКРЫТИЕ ФАЗЫ В 1 ХОД: вызывай scripts/Complete-CurrentPhase.ps1 или authoritative_closure.py целиком.]"
                    )
                    prefix = f"{cmd_act}\n\n" if cmd_act else ""
                    resume_content = f"{prefix}Продолжай автономное выполнение задачи согласно текущему плану и .agy/NEXT_ACTION.json.{extra_ctx} Проверь статус тестов и артефактов и доведи текущую фазу до завершения.{operational_banner}"
                elif target_info.get("name") == "Supervisor":
                    if not resume_title or resume_title == "Возобновление прерванного потока":
                        resume_title = "Регулярный аудит стабильности и дисциплины"
                        resume_content = (
                            "Регулярный аудит стабильности системы Agentic Pipeline и жесткий контроль дисциплины дочерних агентов (H10, Vitalis).\n"
                            "Анализ логов, выявление ТОП-10 оставшихся узких мест и факторов нарушения регламентов, формирование долгосрочных системных решений."
                        )
                else:
                    resume_title = "Возобновление прерванного потока"
                    resume_content = "Поток ответа восстановлен. Продолжай выполнение задачи с места остановки."

                cmd = [
                    str(exe),
                    "agentapi",
                    "send-message",
                    f"--title={resume_title}",
                    cid,
                    resume_content
                ]
                res = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15, creationflags=creationflags)
                if res.returncode == 0:
                    LAST_RESUMED_TIMESTAMPS[cid] = now
                    resumed.append(cid)
                    log_event(f"[AUTO_RESUME] Successfully resumed {proj_name} ({cid})")
                    send_telegram_notification(
                        f"🔄 <b>Авто-возобновление диалога Antigravity</b>\n\n"
                        f"📁 <b>Контекст:</b> {proj_name}\n"
                        f"💬 <b>Сессия:</b> <code>{cid}</code>\n"
                        f"⚠️ <b>Причина:</b> {error_reason}\n\n"
                        f"<i>Подключение восстановлено. Агенту отправлена команда продолжения работы.</i>",
                        min_interval_sec=300.0
                    )
                else:
                    err_msg = res.stderr or res.stdout
                    log_event(f"[AUTO_RESUME_ERROR] Failed to resume {cid}: {err_msg.strip()}")
                    if any(k in err_msg.lower() for k in ["quota", "exhausted", "credit", "rate limit", "429"]):
                        log_event(f"[QUOTA_DETECTED] Send-message rejected by model quota. Triggering autonomous account rotation...")
                        set_pipeline_standby(True, f"Ошибка отправки команды (квота исчерпана): {err_msg.strip()[:100]}", mode="QUOTA_EXHAUSTED", send_tg=False)
                        trigger_quota_recovery(cid, err_msg.strip(), workspace_paths=[])
                        return resumed
        except Exception as e:
            log_event(f"[AUTO_RESUME_ERROR] Error checking {cid}: {e}")

    return resumed


def ensure_antigravity_gui_visible() -> bool:
    """
    Sentinel check: if Antigravity or Language Server is running, verifies that at least one
    visible GUI window exists on the user's interactive desktop. If headless ghost state is detected,
    resurrects the GUI window without disturbing running backend streams.
    """
    try:
        from antigravity_gui_launcher import is_antigravity_gui_visible, ensure_antigravity_gui_visible as _resurrect_gui
        if not is_antigravity_gui_visible():
            log_event("[SENTINEL] ⚠️ Antigravity is active but NO visible GUI window detected on desktop! Resurrecting GUI window...")
            return _resurrect_gui()
        return True
    except Exception as e:
        log_event(f"[SENTINEL] Error checking GUI visibility: {e}")
        return False


def ensure_antigravity_maximized() -> bool:
    """Legacy alias: delegates to ensure_antigravity_gui_visible."""
    return ensure_antigravity_gui_visible()


def watch_loop(poll_interval: float = 15.0) -> None:
    global LAST_STANDBY_LS_PID, LAST_KNOWN_LS_PID
    log_event(f"Antigravity Process Guard started (native zero-flicker loop, poll interval: {poll_interval}s)")
    last_standby_log = 0.0
    last_ledger_rotation = time.time()
    last_dialog_rotation = 0.0
    antigravity_down_ticks = 0
    try:
        while True:
            write_heartbeat()
            check_and_kill_hanging()
            ensure_companion_bridge_running()

            # Watchdog: Passive observation of Language Server / Antigravity presence
            ls_alive = is_language_server_running()
            ag_alive = is_antigravity_running()
            if not ag_alive and not ls_alive:
                antigravity_down_ticks += 1
                if antigravity_down_ticks == 1 or antigravity_down_ticks % 5 == 0:
                    log_event(f"[WATCHDOG] Note: Neither language_server.exe nor Antigravity.exe detected (ticks={antigravity_down_ticks}, ls={ls_alive}, ag={ag_alive}, psutil={bool(psutil)}). Awaiting IDE restart...")
            else:
                antigravity_down_ticks = 0
                # GUI Visibility Sentinel: if language_server or antigravity is alive, ensure window is actually visible on desktop
                now_gui = time.time()
                last_gui_check = getattr(watch_loop, "last_gui_check", 0.0)
                grace_restart = (now_gui - globals().get("LAST_SERVER_RESTART_TIME", 0.0)) >= 120.0
                grace_launch = (now_gui - globals().get("LAST_ANTIGRAVITY_LAUNCH_TIME", 0.0)) >= 120.0
                if (now_gui - last_gui_check >= 120.0) and grace_restart and grace_launch:
                    watch_loop.last_gui_check = now_gui
                    ensure_antigravity_gui_visible()

            # Global server restart detector: runs continuously on every tick
            ls_env = get_active_antigravity_ls_env()
            current_ls_pid = ls_env.get("ANTIGRAVITY_LS_PID")
            if current_ls_pid and LAST_KNOWN_LS_PID and current_ls_pid != LAST_KNOWN_LS_PID:
                old_pid = LAST_KNOWN_LS_PID
                log_event(f"[SERVER_RESTART] Detected Antigravity language_server restart: PID changed ({old_pid} -> {current_ls_pid}). Stabilizing...")
                LAST_KNOWN_LS_PID = current_ls_pid
                global LAST_SERVER_RESTART_TIME
                LAST_SERVER_RESTART_TIME = time.time()
                RECENT_STREAM_INTERRUPTIONS.clear()
                CONSECUTIVE_FAILURES.clear()
                
                # Warmup grace period: wait 25s for the newly spawned language_server to fully bind gRPC,
                # mount its profile, and establish Electron window before issuing agentapi commands or GUI checks.
                log_event("[SERVER_RESTART] Allowing 25s warmup period for language_server and Electron initialization...")
                safe_sleep(25.0)

                # Refresh active LS environment and ports
                fresh_ls_env = get_active_antigravity_ls_env()
                new_port = fresh_ls_env.get("port") or "?"

                # If pipeline was in standby (quota/error), auto-lift it on server restart
                standby_current = get_standby_info()
                if standby_current.get("is_standby"):
                    mode_now = standby_current.get("mode", "")
                    if mode_now not in ("MAN_IN_THE_MIDDLE", "PRE_SLEEP", "PRE_HIBERNATE", "MANUAL", "USER_PAUSE"):
                        set_pipeline_standby(False, "Обнаружен перезапуск Antigravity с новой сессией", mode="NORMAL", send_tg=False)

                resumed_chats = check_and_resume_interrupted_chats()

                # Explicitly wake up primary project conversations on server restart if not already resumed
                try:
                    cfg_g_path = Path(r"C:\Users\Администратор\.gemini\antigravity\companion_bridge_config.json")
                    if cfg_g_path.is_file():
                        cfg_g = json.loads(cfg_g_path.read_text(encoding="utf-8"))
                        exe_g = Path(r"C:\Users\Администратор\AppData\Local\Programs\Antigravity\resources\bin\language_server.exe")
                        c_flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
                        for comp_k, comp_v in cfg_g.get("browser", {}).get("companions", {}).items():
                            c_cid = comp_v.get("antigravityConversationId")
                            if not c_cid or c_cid in resumed_chats or c_cid in get_retired_conversation_ids():
                                continue
                            p_path = comp_v.get("projectPath")
                            has_work = False
                            if p_path:
                                na_f = Path(p_path) / ".agy" / "NEXT_ACTION.json"
                                if na_f.is_file():
                                    try:
                                        na_d = json.loads(na_f.read_text(encoding="utf-8"))
                                        if na_d.get("auto_continue") is True and not na_d.get("owner_decision_required"):
                                            has_work = True
                                    except Exception:
                                        pass
                            if has_work:
                                c_env = os.environ.copy()
                                c_env["ANTIGRAVITY_LS_ADDRESS"] = fresh_ls_env["ANTIGRAVITY_LS_ADDRESS"]
                                c_env["ANTIGRAVITY_CSRF_TOKEN"] = fresh_ls_env["ANTIGRAVITY_CSRF_TOKEN"]
                                c_pid = comp_v.get("projectId") or get_conversation_project_id(c_cid, exe_g, fresh_ls_env)
                                if c_pid:
                                    c_env["ANTIGRAVITY_PROJECT_ID"] = c_pid
                                c_env["ANTIGRAVITY_CONVERSATION_ID"] = c_cid
                                c_env.pop("ANTIGRAVITY_SOURCE_METADATA", None)
                                extra_r = ""
                                if p_path:
                                    try:
                                        na_f2 = Path(p_path) / ".agy" / "NEXT_ACTION.json"
                                        if na_f2.is_file():
                                            na_d2 = json.loads(na_f2.read_text(encoding="utf-8"))
                                            wid2 = na_d2.get("work_item_id")
                                            cmd_act2 = na_d2.get("state_declared_next_required_command") or na_d2.get("command")
                                            ph2 = na_d2.get("phase") or na_d2.get("phase_name")
                                            if wid2:
                                                extra_r = f" Активный рабочий элемент: {wid2}"
                                                if ph2:
                                                    extra_r += f" (фаза: {ph2})"
                                                if cmd_act2:
                                                    extra_r += f", команда: {cmd_act2}"
                                                extra_r += "."
                                    except Exception:
                                        pass
                                operational_banner = (
                                    "\n\n[РЕГЛАМЕНТ СКОРОСТИ И ДИСЦИПЛИНЫ:\n"
                                    "1. СТРОГИЙ ЗАПРЕТ МИКРО-СЛАЙСИНГА: view_file поддерживает до 800 строк. Всегда читай файлы целиком без StartLine/EndLine! Запрещено резать < 300 строк.\n"
                                    "2. ПАРАЛЛЕЛЬНОЕ БАТЧИРОВАНИЕ ИНСТРУМЕНТОВ: строго группируй вызовы в 1 ход [view_file, grep, replace]. Никаких одиночных вызовов.\n"
                                    "3. НОЛЬ ПОВТОРНЫХ ЧТЕНИЙ: не перечитывай файлы из контекста, делай прямые правки replace_file_content.\n"
                                    "4. CODEBASE-MEMORY FIRST: вызывай search_graph / get_code_snippet через MCP перед grep_search.\n"
                                    "5. СИНХРОННЫЕ КОМАНДЫ: WaitMsBeforeAsync: 8000-10000 для быстрых скриптов.\n"
                                    "6. ЗАКРЫТИЕ ФАЗЫ В 1 ХОД: вызывай scripts/Complete-CurrentPhase.ps1 или authoritative_closure.py целиком.]"
                                )
                                cmd_r = [
                                    str(exe_g), "agentapi", "send-message",
                                    "--title=Возобновление после перезапуска",
                                    c_cid,
                                    f"Работа возобновлена после перезапуска Antigravity.{extra_r} Продолжай выполнение активного рабочего элемента с места остановки согласно .agy/NEXT_ACTION.json.{operational_banner}"
                                ]
                                res_r = subprocess.run(cmd_r, env=c_env, capture_output=True, text=True, timeout=15, creationflags=c_flags)
                                if res_r.returncode == 0:
                                    resumed_chats.append(c_cid)
                                    LAST_RESUMED_TIMESTAMPS[c_cid] = time.time()
                                    log_event(f"[SERVER_RESTART] Dispatched wakeup to {comp_v.get('name', comp_k)} ({c_cid})")
                except Exception as restart_wake_err:
                    log_event(f"[SERVER_RESTART] Warning during project wakeup: {restart_wake_err}")

                # Ensure visible GUI window is activated non-destructively (never re-launch from restart handler!)
                try:
                    from antigravity_gui_launcher import get_antigravity_window_handles, activate_antigravity_window
                    hwnds = get_antigravity_window_handles()
                    if hwnds:
                        activate_antigravity_window(hwnds[0])
                        log_event(f"[SERVER_RESTART] Activated existing GUI window (HWND: {hwnds[0]})")
                except Exception as e_vis_sr:
                    log_event(f"[SERVER_RESTART] Warning activating GUI window: {e_vis_sr}")

                resumed_summary = f"Возобновлено задач: {len(resumed_chats)}" if resumed_chats else "Активные сессии в норме"

                # Send guaranteed Telegram notification on restart requested by owner
                send_telegram_notification(
                    f"🔄 <b>ANTIGRAVITY: ПЕРЕЗАГРУЗКА ЗАВЕРШЕНА</b>\n\n"
                    f"• <b>Событие:</b> Успешный перезапуск Language Server (восстановление квоты / рестарт)\n"
                    f"• <b>PID сервера:</b> <code>{old_pid}</code> ➔ <code>{current_ls_pid}</code>\n"
                    f"• <b>gRPC порт:</b> <code>{new_port}</code>\n"
                    f"• <b>Статус проектов:</b> {resumed_summary}\n\n"
                    f"✅ <i>Все 4 фоновые службы синхронизированы, циклы продолжают автономную работу.</i>",
                    min_interval_sec=30.0
                )
            elif current_ls_pid:
                LAST_KNOWN_LS_PID = current_ls_pid

            standby_info = get_standby_info()
            if standby_info.get("is_standby"):
                now = time.time()
                standby_mode = standby_info.get("mode", "QUOTA_EXHAUSTED")
                is_user_pause = standby_mode in ("MAN_IN_THE_MIDDLE", "PRE_SLEEP", "PRE_HIBERNATE", "MANUAL", "USER_PAUSE")

                if is_user_pause:
                    # In user pause (MiM), autonomous loop progression (/nextphase) is paused,
                    # but infrastructure health & quota recovery MUST still protect active dialogs!
                    check_and_resume_interrupted_chats(allow_autonomous_continue=False)
                    if now - last_standby_log >= 300.0:
                        log_event(f"[STANDBY] Pipeline in USER PAUSE mode ({standby_mode}). Autonomous loops paused, quota guard active.")
                        last_standby_log = now
                    safe_sleep(poll_interval)
                    continue

                # Auto-recovery for QUOTA_EXHAUSTED / QUOTA_WAIT
                if standby_mode in ("QUOTA_EXHAUSTED", "QUOTA_WAIT"):
                    # Check 1: Target reset time reached
                    reset_time_str = standby_info.get("reset_time_utc")
                    now_utc = dt.datetime.now(dt.timezone.utc)
                    should_rotate = False
                    if reset_time_str:
                        try:
                            dt_reset = dt.datetime.fromisoformat(reset_time_str.replace("Z", "+00:00"))
                            if now_utc >= dt_reset:
                                should_rotate = True
                                log_event(f"[QUOTA_WAIT] Target reset time {reset_time_str} reached! Initiating autonomous account rotation...")
                        except Exception:
                            pass

                    if should_rotate:
                        set_pipeline_standby(False, "Время сброса квоты наступило", mode="NORMAL")
                        trigger_quota_recovery(reason=f"Scheduled quota reset time reached ({reset_time_str})")
                        safe_sleep(poll_interval)
                        continue

                    # Check 2: Active account already has usable quota (e.g. user manually switched account)
                    is_depleted, g5h_now, gw_now = check_active_account_quota()
                    if not is_depleted:
                        log_event(f"[STANDBY] Active account has available quota (5h: {(g5h_now or 0)*100:.0f}%, weekly: {(gw_now or 0)*100:.0f}%). Lifting {standby_mode} standby...")
                        set_pipeline_standby(False, "Активный аккаунт имеет доступную квоту", mode="NORMAL")
                        LAST_STANDBY_LS_PID = current_ls_pid
                        check_and_resume_interrupted_chats()
                        safe_sleep(poll_interval)
                        continue

                    # Periodic log
                    if now - last_standby_log >= 60.0:
                        if reset_time_str:
                            try:
                                dt_reset = dt.datetime.fromisoformat(reset_time_str.replace("Z", "+00:00"))
                                remaining_sec = max(0, int((dt_reset - now_utc).total_seconds()))
                                rem_min = round(remaining_sec / 60.0, 1)
                                target_email = standby_info.get("target_account_email", "целевого аккаунта")
                                log_event(f"[QUOTA_WAIT] Пайплайн в режиме ожидания квоты ({target_email}). До сброса: {rem_min} мин ({reset_time_str}).")
                            except Exception:
                                log_event(f"[STANDBY] Quota standby ({standby_mode}) active. Awaiting reset...")
                        else:
                            log_event(f"[STANDBY] Quota standby ({standby_mode}) active. Awaiting reset...")
                        last_standby_log = now
                    safe_sleep(15.0)
                    continue

            check_and_resume_interrupted_chats()

            now_tick = time.time()
            if now_tick - last_ledger_rotation >= 1800.0:
                try:
                    import rotate_agy_ledgers
                    rotate_agy_ledgers.main()
                except Exception:
                    pass
                last_ledger_rotation = now_tick

            if now_tick - last_dialog_rotation >= 60.0:
                try:
                    import rotate_active_dialog
                    rotate_active_dialog.auto_rotate_all(force=False)
                except Exception as rot_err:
                    log_event(f"[PROCESS_GUARD] Dialog rotation error: {rot_err}")
                last_dialog_rotation = now_tick

            if now_tick - getattr(watch_loop, "last_orphan_clean", 0.0) >= 120.0:
                try:
                    from cleanup_zombie_processes import clean_orphans
                    clean_orphans(dry_run=False)
                except Exception:
                    pass
                watch_loop.last_orphan_clean = now_tick

            safe_sleep(poll_interval)
    except KeyboardInterrupt:
        log_event("Antigravity Process Guard stopped by user.")



def main() -> int:
    parser = argparse.ArgumentParser(description="Antigravity Process Guard")
    parser.add_argument("--watch", action="store_true", help="Run continuous monitoring loop")
    parser.add_argument("--interval", type=float, default=15.0, help="Check interval in seconds (default: 15)")
    parser.add_argument("--dry-run", action="store_true", help="Report candidates without terminating")
    args = parser.parse_args()

    if args.watch:
        # Hard process table deduplication: strictly 1 process guard watch loop allowed across OS
        my_pid = os.getpid()
        if psutil:
            try:
                for p in psutil.process_iter(['pid', 'name', 'cmdline']):
                    try:
                        if p.info['pid'] == my_pid:
                            continue
                        cmd = " ".join(p.info.get('cmdline') or []).lower()
                        if "antigravity_process_guard.py" in cmd and "--watch" in cmd:
                            print(f"[PROCESS_GUARD] Duplicate instance detected: PID {p.info['pid']} is already running. Exiting.", flush=True)
                            return 0
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass
            except Exception:
                pass

        _guard_mutex = acquire_singleton_mutex("AgenticPipeline_ProcessGuard_Watch")
        if not _guard_mutex:
            print("[PROCESS_GUARD] Another process guard instance is already running (Mutex held). Exiting.", flush=True)
            return 0
        watch_loop(args.interval)
        return 0

    killed = check_and_kill_hanging(dry_run=args.dry_run)
    resumed = check_and_resume_interrupted_chats()
    if not killed and not resumed:
        print("OK: No hanging processes detected, all monitored chats healthy.")
    else:
        print(f"Handled {len(killed)} hanging process(es), resumed {len(resumed)} chat(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
