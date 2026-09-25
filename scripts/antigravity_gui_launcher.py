"""
Antigravity GUI Launcher & Window Visibility Sentinel.
Guarantees that Google Antigravity IDE runs with a visible window on the user's
interactive desktop, prevents phantom headless/windowless states after quota rotation,
cleans stale Chromium lockfiles, resets runInBackground, and handles foreground activation.
"""

import os
import sys
import time
import json
from pathlib import Path



import ctypes
from ctypes import wintypes

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

ANTIGRAVITY_EXE = Path(os.path.expandvars(r"%LOCALAPPDATA%\Programs\antigravity\Antigravity.exe"))
APP_DATA_ROAMING = Path(os.path.expandvars(r"%APPDATA%\Antigravity"))
APP_DATA_IDE = Path(os.path.expandvars(r"%APPDATA%\Antigravity IDE"))
CONFIG_PATH = Path(os.path.expandvars(r"%USERPROFILE%\.gemini\antigravity\companion_bridge_config.json"))


def get_active_workspace_paths() -> list[str]:
    """Retrieves all registered project workspaces from companion_bridge_config.json."""
    workspaces = []
    try:
        if CONFIG_PATH.is_file():
            cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            for comp_k, comp_v in cfg.get("browser", {}).get("companions", {}).items():
                p_path = comp_v.get("projectPath")
                if p_path and os.path.isdir(p_path) and p_path not in workspaces:
                    workspaces.append(p_path)
    except Exception:
        pass
    
    # Also include Agentic Pipeline workspace if not already present
    pipeline_dir = r"C:\Users\Администратор\Documents\antigravity\Agentic Pipeline"
    if os.path.isdir(pipeline_dir) and pipeline_dir not in workspaces:
        workspaces.append(pipeline_dir)
        
    return workspaces


def is_any_antigravity_process_running() -> bool:
    """Returns True if any Antigravity or Language Server process is currently alive."""
    try:
        import psutil
        for p in psutil.process_iter(['name']):
            try:
                name = (p.info['name'] or '').lower()
                if name in ('antigravity.exe', 'language_server.exe'):
                    return True
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except Exception:
        pass
    return False


def reset_background_and_lock_flags() -> None:
    """Clears stale Chromium lockfiles and forces runInBackground=false."""
    # 0. Clean environment: scrub any leaked ELECTRON_OZONE_PLATFORM_HINT
    os.environ.pop("ELECTRON_OZONE_PLATFORM_HINT", None)

    # 1. Reset runInBackground in app_storage.json
    storage_file = APP_DATA_ROAMING / "app_storage.json"
    if storage_file.is_file():
        try:
            txt = storage_file.read_text(encoding="utf-8")
            if '"runInBackground": "true"' in txt or '"runInBackground":"true"' in txt or '"runInBackground": true' in txt or '"runInBackground":true' in txt:
                txt = txt.replace('"runInBackground": "true"', '"runInBackground": "false"')
                txt = txt.replace('"runInBackground":"true"', '"runInBackground":"false"')
                txt = txt.replace('"runInBackground": true', '"runInBackground": "false"')
                txt = txt.replace('"runInBackground":true', '"runInBackground":"false"')
                storage_file.write_text(txt, encoding="utf-8")
        except Exception:
            pass

    # 2. Remove stale lockfiles from both Antigravity profiles ONLY if processes are completely dead!
    # Deleting SingletonLock or DevToolsActivePort while Antigravity is running corrupts Chromium profile state.
    if not is_any_antigravity_process_running():
        lock_names = ("lockfile", "DevToolsActivePort", "SingletonLock", "SingletonSocket", "SingletonCookie")
        for profile_dir in (APP_DATA_ROAMING, APP_DATA_IDE):
            if profile_dir.is_dir():
                for lname in lock_names:
                    lp = profile_dir / lname
                    if lp.is_file():
                        for _ in range(5):
                            try:
                                lp.unlink(missing_ok=True)
                                break
                            except Exception:
                                time.sleep(0.2)


def get_antigravity_window_handles() -> list[int]:
    """Finds all visible top-level HWNDs for Antigravity on the user interactive desktop (Default)."""
    hwnds = []

    h_orig_desk = user32.GetThreadDesktop(kernel32.GetCurrentThreadId())
    h_desk = user32.OpenDesktopW("Default", 0, False, 0x01FF)
    if not h_desk:
        h_desk = user32.OpenDesktopW("Default", 0, False, 0x0001 | 0x0040 | 0x0002 | 0x0100)

    switched = False
    if h_desk:
        switched = bool(user32.SetThreadDesktop(h_desk))

    try:
        def enum_cb(hwnd, lparam):
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if pid.value:
                try:
                    import psutil
                    proc = psutil.Process(pid.value)
                    if proc.name().lower() == "antigravity.exe":
                        cls_name = ctypes.create_unicode_buffer(256)
                        user32.GetClassNameW(hwnd, cls_name, 256)
                        rect = wintypes.RECT()
                        user32.GetWindowRect(hwnd, ctypes.byref(rect))
                        w = rect.right - rect.left
                        h = rect.bottom - rect.top
                        is_vis = bool(user32.IsWindowVisible(hwnd))
                        is_min = bool(user32.IsIconic(hwnd))
                        if (is_vis or is_min or "Chrome_WidgetWin_1" in cls_name.value) and (w > 200 and h > 200 or is_min):
                            hwnds.append(hwnd)
                except Exception:
                    pass
            return True

        WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
        if h_desk:
            user32.EnumDesktopWindows(h_desk, WNDENUMPROC(enum_cb), 0)
        else:
            user32.EnumWindows(WNDENUMPROC(enum_cb), 0)
    finally:
        if switched and h_orig_desk:
            user32.SetThreadDesktop(h_orig_desk)
        if h_desk:
            user32.CloseDesktop(h_desk)

    return hwnds


def is_antigravity_gui_visible() -> bool:
    """Returns True ONLY if at least one genuine GUI window of Antigravity is on the desktop."""
    hwnds = get_antigravity_window_handles()
    return len(hwnds) > 0


def activate_antigravity_window(hwnd: int) -> bool:
    """Brings the given Antigravity HWND to the foreground on the user's screen."""
    h_orig_desk = user32.GetThreadDesktop(kernel32.GetCurrentThreadId())
    h_desk = user32.OpenDesktopW("Default", 0, False, 0x01FF)
    switched = False
    if h_desk:
        switched = bool(user32.SetThreadDesktop(h_desk))

    try:
        user32.AllowSetForegroundWindow(-1)
        user32.ShowWindow(hwnd, 5)  # SW_SHOW = 5
        user32.ShowWindowAsync(hwnd, 9)  # SW_RESTORE = 9
        user32.SetWindowPos(hwnd, 0, 0, 0, 0, 0, 0x0043)  # SWP_SHOWWINDOW | SWP_NOMOVE | SWP_NOSIZE
        
        cur_tid = kernel32.GetCurrentThreadId()
        w_tid = user32.GetWindowThreadProcessId(hwnd, None)
        if cur_tid and w_tid:
            user32.AttachThreadInput(cur_tid, w_tid, True)
            user32.SetForegroundWindow(hwnd)
            user32.AttachThreadInput(cur_tid, w_tid, False)
        else:
            user32.SetForegroundWindow(hwnd)
        return True
    except Exception:
        return False
    finally:
        if switched and h_orig_desk:
            user32.SetThreadDesktop(h_orig_desk)
        if h_desk:
            user32.CloseDesktop(h_desk)


def launch_antigravity_visible(workspace_paths: list[str] = None, restart: bool = False) -> bool:
    """
    Launches Antigravity with a guaranteed visible window and registers active workspaces.
    Uses Launch-AntigravityVisible.ps1 as primary engine with direct Win32 fallback.
    """
    if not ANTIGRAVITY_EXE.is_file():
        return False

    if workspace_paths is None:
        workspace_paths = get_active_workspace_paths()

    # Ensure headless environment variable is never inherited
    os.environ.pop("ELECTRON_OZONE_PLATFORM_HINT", None)

    reset_background_and_lock_flags()
    if user32:
        try:
            user32.AllowSetForegroundWindow(-1)
        except Exception:
            pass

    # 1. Primary: Run canonical PowerShell visible launcher
    launcher_ps1 = Path(r"C:\Scripts\AntigravityProjects\companion-handoff\src\Launch-AntigravityVisible.ps1")
    if not launcher_ps1.is_file():
        launcher_ps1 = Path(__file__).parent / "Launch-AntigravityVisible.ps1"

    if launcher_ps1.is_file():
        try:
            import subprocess
            cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(launcher_ps1)]
            if restart:
                cmd.append("-Restart")
            if workspace_paths:
                cmd.append("-WorkspacePaths")
                cmd.extend(workspace_paths)
            
            res = subprocess.run(cmd, capture_output=True, timeout=65)
            if res.returncode == 0:
                time.sleep(2.0)
                hwnds = get_antigravity_window_handles()
                if hwnds:
                    activate_antigravity_window(hwnds[0])
                    return True
        except Exception:
            pass

    # 2. Fallback: Direct ShellExecuteExW with explicit SW_SHOWNORMAL (ONLY if NO process is running)
    if not is_any_antigravity_process_running():
        try:
            class SHELLEXECUTEINFOW(ctypes.Structure):
                _fields_ = [
                    ("cbSize", wintypes.DWORD),
                    ("fMask", wintypes.ULONG),
                    ("hwnd", wintypes.HWND),
                    ("lpVerb", wintypes.LPCWSTR),
                    ("lpFile", wintypes.LPCWSTR),
                    ("lpParameters", wintypes.LPCWSTR),
                    ("lpDirectory", wintypes.LPCWSTR),
                    ("nShow", ctypes.c_int),
                    ("hInstApp", wintypes.HINSTANCE),
                    ("lpIDList", wintypes.LPVOID),
                    ("lpClass", wintypes.LPCWSTR),
                    ("hkeyClass", wintypes.HKEY),
                    ("dwHotKey", wintypes.DWORD),
                    ("hIcon", wintypes.HANDLE),
                    ("hProcess", wintypes.HANDLE),
                ]

            shell32 = ctypes.windll.shell32
            
            target_ws = workspace_paths[0] if workspace_paths else ""
            args = (
                f"--disable-features=UseEcoQoSForBackgroundProcess "
                f"--disable-renderer-backgrounding "
                f"--disable-background-timer-throttling "
                f"--disable-backgrounding-occluded-windows "
                f"--new-window \"{target_ws}\""
            )
            
            sei = SHELLEXECUTEINFOW()
            sei.cbSize = ctypes.sizeof(SHELLEXECUTEINFOW)
            sei.fMask = 0x00000040  # SEE_MASK_NOCLOSEPROCESS
            sei.lpVerb = "open"
            sei.lpFile = str(ANTIGRAVITY_EXE)
            sei.lpParameters = args
            sei.lpDirectory = str(ANTIGRAVITY_EXE.parent)
            sei.nShow = 1  # SW_SHOWNORMAL
            
            if shell32.ShellExecuteExW(ctypes.byref(sei)):
                time.sleep(3.0)
                hwnds = get_antigravity_window_handles()
                if hwnds:
                    activate_antigravity_window(hwnds[0])
                    return True
        except Exception:
            pass

    return False


_LAST_RESURRECT_TIME = 0.0


def ensure_antigravity_gui_visible() -> bool:
    """
    Sentinel check: if Antigravity or Language Server is running but NO visible window
    exists on the interactive desktop, or if it is occluded/minimized, brings it to life.
    Non-destructive: never terminates running backend processes while agent tasks are active!
    Includes strict 120-second debounce to prevent recursive re-launch loops while Antigravity is starting up.
    """
    global _LAST_RESURRECT_TIME
    hwnds = get_antigravity_window_handles()
    if hwnds:
        # Window exists: ensure it's not minimized or lost behind occluded windows
        activate_antigravity_window(hwnds[0])
        return True

    # If Antigravity process is running, give it a moment to render before attempting re-launch
    if is_any_antigravity_process_running():
        for _ in range(5):
            time.sleep(1.0)
            hwnds = get_antigravity_window_handles()
            if hwnds:
                activate_antigravity_window(hwnds[0])
                return True
    
    now = time.time()
    if now - _LAST_RESURRECT_TIME < 120.0:
        return False

    _LAST_RESURRECT_TIME = now
    # No visible window detected: launch a new window without destructive process killing
    return launch_antigravity_visible(restart=False)


if __name__ == "__main__":
    visible = is_antigravity_gui_visible()
    print(f"Antigravity GUI visible: {visible}")
    if not visible:
        print("Launching visible Antigravity window...")
        ok = launch_antigravity_visible()
        print(f"Launch result: {ok}")
    else:
        hwnds = get_antigravity_window_handles()
        print(f"Active window handles: {[hex(h) for h in hwnds]}")
        activate_antigravity_window(hwnds[0])
        print("Window activated on foreground.")
