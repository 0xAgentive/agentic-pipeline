#!/usr/bin/env python3
"""
trigger_supervisor_diagnostic.py - Autonomous Diagnostic Trigger for Antigravity Supervisor.

When an autonomous cycle (H10, Vitalis, etc.) is stalled, frozen, or encounters a repeated blocker,
this script wakes up the Antigravity Supervisor dialogue (b181c7df-b538-4519-96c8-589605172fdb)
via language_server.exe agentapi send-message with actionable diagnostics so that Antigravity
diagnoses and restores the pipeline autonomously without requiring manual user intervention.
"""

import sys
import os
import json
import time
import argparse
import subprocess
from pathlib import Path

DEFAULT_SUPERVISOR_CONVERSATION_ID = "b181c7df-b538-4519-96c8-589605172fdb"
DEFAULT_SUPERVISOR_PROJECT_ID = "20de8681-6ad2-446a-acd9-99509e423fb5"
CREATE_NO_WINDOW = 0x08000000


def get_paths():
    home = Path.home()
    config_path = home / ".gemini" / "antigravity" / "companion_bridge_config.json"
    state_root = home / ".agentic-pipeline" / "action-bridge"
    exe_path = home / "AppData" / "Local" / "Programs" / "Antigravity" / "resources" / "bin" / "language_server.exe"
    logs_dir = state_root / "logs"
    return config_path, state_root, exe_path, logs_dir


def log_event(message: str, logs_dir: Path):
    try:
        logs_dir.mkdir(parents=True, exist_ok=True)
        log_file = logs_dir / "supervisor_triggers.log"
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(f"[{timestamp}] {message}\n")
    except Exception:
        pass


def trigger_diagnostic(
    project_key: str,
    reason: str,
    details: str = "",
    supervisor_id: str = None,
    stalled_minutes: int = 15
) -> dict:
    config_path, state_root, exe_path, logs_dir = get_paths()

    if not exe_path.is_file():
        err = f"language_server.exe not found at {exe_path}"
        log_event(f"[ERROR] {err}", logs_dir)
        return {"ok": False, "error": err}

    # Load configuration
    cfg = {}
    if config_path.is_file():
        try:
            cfg = json.loads(config_path.read_text(encoding="utf-8-sig"))
        except Exception as e:
            log_event(f"[WARN] Failed to parse config: {e}", logs_dir)

    target_supervisor_id = (
        supervisor_id or
        cfg.get("supervisor", {}).get("antigravityConversationId") or
        DEFAULT_SUPERVISOR_CONVERSATION_ID
    )
    supervisor_project_id = (
        cfg.get("supervisor", {}).get("projectId") or
        DEFAULT_SUPERVISOR_PROJECT_ID
    )

    comp_info = cfg.get("browser", {}).get("companions", {}).get(project_key, {})
    project_name = comp_info.get("name", project_key.upper())
    project_path = comp_info.get("projectPath", "Unknown path")
    executor_conv_id = comp_info.get("antigravityConversationId", "Unknown conversation")

    # Load active language server environment
    env_file = state_root / "ACTIVE_LS_ENV.json"
    if not env_file.is_file():
        err = f"ACTIVE_LS_ENV.json not found in {state_root}"
        log_event(f"[ERROR] {err}", logs_dir)
        return {"ok": False, "error": err}

    try:
        ls_env = json.loads(env_file.read_text(encoding="utf-8"))
    except Exception as e:
        err = f"Failed to parse ACTIVE_LS_ENV.json: {e}"
        log_event(f"[ERROR] {err}", logs_dir)
        return {"ok": False, "error": err}

    env = os.environ.copy()
    env.pop("ANTIGRAVITY_SOURCE_METADATA", None)
    for k in ["ANTIGRAVITY_LS_ADDRESS", "ANTIGRAVITY_CSRF_TOKEN", "ANTIGRAVITY_LS_PID"]:
        if k in ls_env and ls_env[k]:
            env[k] = str(ls_env[k])

    if supervisor_project_id:
        env["ANTIGRAVITY_PROJECT_ID"] = str(supervisor_project_id)
    env["ANTIGRAVITY_CONVERSATION_ID"] = str(target_supervisor_id)

    title = f"⚠️ [WATCHDOG ALERT] Простой цикла {project_name}"
    prompt = (
        f"⚠️ [WATCHDOG DIAGNOSTIC ALERT] Зафиксирован простой цикла: {project_name} ({project_key})\n\n"
        f"Параметры инцидента:\n"
        f"• Проект: {project_name}\n"
        f"• Рабочая директория: {project_path}\n"
        f"• Причина вызова: {reason}\n"
        f"• Время простоя: {stalled_minutes} мин.\n"
        f"• Диалог исполнителя задачи: {executor_conv_id}\n"
        f"• Дополнительные детали: {details or 'нет'}\n\n"
        f"ДИРЕКТИВА ДЛЯ СУПЕРВИЗОРА (Antigravity):\n"
        f"1. Проведи немедленную диагностику состояния control plane (.agy/WORK_ITEM.json, NEXT_ACTION.json, CLOSURE_STATE.json, RUN_RESULT.json, RUNTIME_HANDSHAKE.json).\n"
        f"2. Проверь состояние транспорта DurableTransport в transport.sqlite3 и логах companion_bridge_service.log.\n"
        f"3. Выяви точную причину остановки (несогласованность work_item_id, непродвинутый статус PACKET_IMPORTED/WAIT_EXTERNAL, зависание исполнителя).\n"
        f"4. Выполни устранение блокировки (выравнивание work_item_id, продвижение транспорта в WORK_COMPLETE, перезапуск или отправка директивы исполнителю).\n"
        f"5. Возобнови непрерывный автономный цикл и кратко зафиксируй результат восстановления."
    )

    cmd = [
        str(exe_path),
        "agentapi",
        "send-message",
        f"--title={title}",
        target_supervisor_id,
        prompt
    ]

    log_event(
        f"[TRIGGER_START] Triggering diagnostic dialogue for {project_key} (target conversation: {target_supervisor_id})...",
        logs_dir
    )

    try:
        res = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
            creationflags=CREATE_NO_WINDOW
        )
        if res.returncode == 0:
            log_event(f"[TRIGGER_SUCCESS] Diagnostic message delivered to {target_supervisor_id}", logs_dir)
            return {
                "ok": True,
                "conversation_id": target_supervisor_id,
                "project_key": project_key,
                "output": res.stdout.strip()
            }
        else:
            err = res.stderr.strip() or res.stdout.strip()
            log_event(f"[TRIGGER_FAILED] Exit {res.returncode}: {err}", logs_dir)
            return {"ok": False, "error": err, "returncode": res.returncode}
    except Exception as e:
        err = f"Subprocess exception: {e}"
        log_event(f"[TRIGGER_EXCEPTION] {err}", logs_dir)
        return {"ok": False, "error": err}


def main():
    parser = argparse.ArgumentParser(description="Trigger Antigravity Supervisor Diagnostic Dialogue")
    parser.add_argument("--project-key", required=True, help="Project key (e.g. vitalis, h10)")
    parser.add_argument("--reason", default="STALLED_CYCLE_TIMEOUT", help="Reason for triggering diagnostic")
    parser.add_argument("--details", default="", help="Additional details or state information")
    parser.add_argument("--supervisor-id", default=None, help="Supervisor conversation ID override")
    parser.add_argument("--stalled-minutes", type=int, default=15, help="Minutes elapsed without progress")

    args = parser.parse_args()
    result = trigger_diagnostic(
        project_key=args.project_key,
        reason=args.reason,
        details=args.details,
        supervisor_id=args.supervisor_id,
        stalled_minutes=args.stalled_minutes
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
