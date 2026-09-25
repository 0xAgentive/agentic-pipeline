#!/usr/bin/env python3
"""
Autonomous Zombie & Orphan Process Hygiene Cleaner for Agentic Pipeline and Subprojects.
Scans and terminates orphan vitest, electron, vite, uvicorn, and detached test processes across all workspace projects.
"""
import os
import sys
import subprocess
from pathlib import Path

WORKSPACE_ROOTS = [
    Path(r"C:\Users\Администратор\Documents\antigravity\H10 Athlete Cardio Lab"),
    Path(r"C:\Users\Администратор\Documents\antigravity\Huawei Health export"),
    Path(r"C:\Users\Администратор\Documents\antigravity\Agentic Pipeline"),
]

PROTECTED_NAMES = {
    "antigravity.exe",
    "language_server.exe",
    "antigravity_tools.exe",
    "code.exe",
    "cursor.exe",
}

PROTECTED_TOKENS = [
    "companion_bridge.js",
    "daemon_supervisor.py",
    "antigravity_process_guard.py",
    "antigravity_tools",
    "telegram_bot",
    "telegram_cycle_bot",
    "language_server.exe",
    "antigravity.exe",
    "quota_recovery",
]

def kill_process_tree(pid: int):
    if sys.platform == "win32":
        try:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=5)
        except Exception:
            pass

def clean_orphans(dry_run: bool = False, force: bool = False):
    try:
        import psutil
    except ImportError:
        print("[HYGIENE] psutil not available, skipping deep process inspection")
        return 0

    my_pid = os.getpid()
    killed = 0

    workspace_strs = [str(r).lower() for r in WORKSPACE_ROOTS]

    # Pre-pass: Deduplicate essential daemons (keep oldest instance, kill duplicate spawns)
    daemon_tokens = {
        "antigravity_process_guard.py": [],
        "daemon_supervisor.py": [],
        "quota_recovery_engine.py": [],
        "telegram_cycle_bot.py": [],
    }

    for p in psutil.process_iter(['pid', 'name', 'cmdline', 'create_time', 'memory_info']):
        try:
            pid = p.info['pid']
            if pid == my_pid:
                continue
            cmdline = " ".join(p.info.get('cmdline') or []).lower()
            name = (p.info.get('name') or '').lower()

            # Skip protected Antigravity and Language Server
            if name in PROTECTED_NAMES:
                continue

            # Memory ceiling guard: kill any runaway python process consuming > 750 MB RAM
            if 'python' in name:
                mem = getattr(p.info.get('memory_info'), 'rss', 0)
                if mem > 750 * 1024 * 1024 and 'language_server' not in cmdline:
                    print(f"[HYGIENE] Terminating RAM-leaking Python process {pid} (RSS: {mem//(1024*1024)} MB): {cmdline[:80]}")
                    kill_process_tree(pid)
                    killed += 1
                    continue

            for dtoken in daemon_tokens:
                if dtoken in cmdline:
                    daemon_tokens[dtoken].append((p.info['create_time'], pid, cmdline))
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    for dtoken, instances in daemon_tokens.items():
        if len(instances) > 1:
            # Sort by create_time ascending (oldest first)
            instances.sort(key=lambda x: x[0])
            oldest = instances[0]
            for _, dup_pid, dup_cmd in instances[1:]:
                print(f"[HYGIENE] Eliminating duplicate daemon {dup_pid} ({dtoken}) - keeping primary PID {oldest[1]}: {dup_cmd[:80]}")
                kill_process_tree(dup_pid)
                killed += 1

    for p in psutil.process_iter(['pid', 'name', 'cmdline', 'cwd']):
        try:
            pid = p.info['pid']
            if pid == my_pid:
                continue
            name = (p.info.get('name') or '').lower()
            cmdline = " ".join(p.info.get('cmdline') or []).lower()
            cwd = str(p.info.get('cwd') or '').lower()

            # ABSOLUTE IMMUNITY: Skip protected system and pipeline daemons
            if name in PROTECTED_NAMES:
                continue
            if any(token in cmdline for token in PROTECTED_TOKENS):
                continue
            if any(token in name for token in ["antigravity", "language_server"]):
                continue

            # 1. Orphan vitest / playwright test runners
            is_orphan_test_runner = (
                any(tok in cmdline for tok in ["vitest", "playwright"]) and
                any(ws in cmdline or ws in cwd for ws in workspace_strs)
            )

            # 1b. Genuine orphan electron test runner (NOT Antigravity)
            is_orphan_electron = (
                name in ("electron.exe", "electron") and
                any(ws in cmdline or ws in cwd for ws in workspace_strs) and
                not ("antigravity" in cmdline or "antigravity" in name)
            )

            # 2. Orphan vite dev / preview servers
            is_orphan_vite = (
                ("vite" in cmdline or "vite" in name) and
                any(ws in cmdline or ws in cwd or "preview" in cmdline for ws in workspace_strs)
            )

            # 3. Orphan test uvicorn server from Vitalis (exclude standard dev server on 2560 if needed)
            is_orphan_uvicorn = (
                "uvicorn" in cmdline and "backend.app:app" in cmdline and "--port" in cmdline
                and not ("--port 2560" in cmdline)
            )

            # 4. Detached cmd/powershell wrappers running test/vite scripts
            is_orphan_shell = (
                name in ("cmd.exe", "powershell.exe", "pwsh.exe") and
                any(tok in cmdline for tok in ["vite", "preview", "playwright", "vitest", "test_uvicorn"]) and
                any(ws in cmdline or ws in cwd for ws in workspace_strs)
            )

            # 5. Hanging node test worker
            is_orphan_node = (
                "node" in name and
                any(tok in cmdline for tok in ["vitest/dist", "run_vitest_and_log.js"]) and
                any(ws in cmdline or ws in cwd for ws in workspace_strs)
            )

            if is_orphan_test_runner or is_orphan_vite or is_orphan_uvicorn or is_orphan_shell or is_orphan_node:
                # If not forced, require process to be older than 120s so active tests are not disrupted
                if not force:
                    try:
                        import time
                        if time.time() - p.create_time() < 120.0:
                            continue
                    except Exception:
                        pass

                if dry_run:
                    print(f"[HYGIENE][DRY-RUN] Detected orphan process {pid} ({name}): {cmdline[:80]}")
                    killed += 1
                else:
                    print(f"[HYGIENE] Terminating orphan process {pid} ({name}): {cmdline[:80]}")
                    kill_process_tree(pid)
                    killed += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
        except Exception:
            pass

    if killed > 0:
        action = "Detected" if dry_run else "Successfully eliminated"
        print(f"[HYGIENE] {action} {killed} orphan process(es).")
    else:
        print("[HYGIENE] Global process state clean. Zero orphan processes detected.")
    return killed

if __name__ == "__main__":
    is_dry = "--dry-run" in sys.argv
    is_force = "--force" in sys.argv or "--all" in sys.argv
    sys.exit(0 if clean_orphans(dry_run=is_dry, force=is_force) >= 0 else 1)

