#!/usr/bin/env python3
"""
Agentic Pipeline — Standby & Power Management Controller.
Controls pipeline pause, Man-in-the-Middle manual takeover, safe sleep, and graceful resumption.

Guarantees:
1. Atomic standby state persistence in STANDBY_STATE.json.
2. Man-in-the-Middle (MitM) mode: freezes automated nudges, reloads, and context pushes,
   allowing the owner to chat directly with ChatGPT or inspect browser tabs.
3. Graceful resumption: measures pause duration, calibrates timers in companion_bridge.js,
   activates a 60s post-pause grace period, and immediately searches for newly generated Action Packets.
4. Safe Sleep / Hibernation: pauses pipeline state prior to initiating OS suspend, preventing
   race conditions or broken CDP sockets.
5. Telegram alerts informing the owner when the pipeline is paused, resumed, or entering sleep.
"""
from runtime_paths import runtime_path

import os
from pipeline_runtime_state import snapshot as runtime_snapshot, owner_set as runtime_owner_set
import sys
import json
import time
import subprocess
import urllib.request
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Dict, Any

# Ensure stdout handles UTF-8 on Windows
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

STANDBY_STATE_PATH = Path(runtime_path("AGENTIC_STATE_ROOT","STANDBY_STATE.json"))
SEEN_PACKETS_PATH = Path(runtime_path("ANTIGRAVITY_DATA_ROOT","companion_seen_packets.json"))
CONFIG_PATH = Path(runtime_path("ANTIGRAVITY_DATA_ROOT","companion_bridge_config.json"))
LOG_FILE_PATH = Path(runtime_path("AGENTIC_STATE_ROOT","logs/companion_bridge.log"))


def load_config() -> dict:
    if CONFIG_PATH.is_file():
        try:
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def send_telegram(html_message: str):
    """Sends HTML notification to the owner's Telegram channel if configured."""
    cfg = load_config().get("telegram", {})
    if not cfg.get("enabled"):
        return
    token = cfg.get("botToken")
    chat_id = cfg.get("chatId")
    if not token or not chat_id:
        return

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps({
        "chat_id": chat_id,
        "text": html_message,
        "parse_mode": "HTML",
        "disable_web_page_preview": True
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            pass
    except Exception as e:
        pass


def get_standby_state() -> dict:
    return runtime_snapshot()


def _sync_standby_file(enabled: bool, mode: str, reason: str):
    try:
        data = {
            "is_standby": enabled,
            "mode": mode if enabled else "NORMAL",
            "reason": reason,
            "updated_at_utc": datetime.now(timezone.utc).isoformat()
        }
        STANDBY_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STANDBY_STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(STANDBY_STATE_PATH)
    except Exception:
        pass


def set_standby_state(enabled: bool, mode: str = "MAN_IN_THE_MIDDLE", reason: str = "", user_note: str = "") -> dict:
    res = runtime_owner_set(enabled, mode, reason or user_note)
    _sync_standby_file(enabled, mode, reason or user_note)
    return res


def get_bridge_process_status() -> dict:
    """Checks if companion_bridge.js is running in Node.js via native psutil."""
    try:
        import psutil
        for p in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if (p.info['name'] or '').lower() == 'node.exe':
                    cl = ' '.join(p.info['cmdline'] or [])
                    if 'companion_bridge.js' in cl:
                        return {"running": True, "pid": p.info['pid'], "command": cl}
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except Exception:
        pass
    return {"running": False, "pid": None, "command": None}



def get_projects_summary() -> dict:
    """Reads companion_seen_packets.json to summarize active turn states."""
    res = {"h10": {"state": "UNKNOWN", "last_packet": "-"}, "vitalis": {"state": "UNKNOWN", "last_packet": "-"}}
    if SEEN_PACKETS_PATH.is_file():
        try:
            data = json.loads(SEEN_PACKETS_PATH.read_text(encoding="utf-8"))
            for key in ["h10", "vitalis"]:
                p = data.get(key, {})
                res[key] = {
                    "state": p.get("turnState", "READY_FOR_CONTEXT"),
                    "last_packet": p.get("fileName") or p.get("lastPacketId") or "нет",
                    "nudge_retries": p.get("nudgeRetries", 0),
                    "last_pushed_at": p.get("lastPushedAt", "-")
                }
        except Exception:
            pass
    return res


def pause_pipeline(mode: str = "MAN_IN_THE_MIDDLE", reason: str = "", user_note: str = "") -> dict:
    if not reason:
        if mode == "MAN_IN_THE_MIDDLE":
            reason = "Ручное управление (Man-in-the-Middle) — переписка / правка промптов"
        elif mode == "PRE_SLEEP":
            reason = "Подготовка к спящему режиму ПК"
        elif mode == "PRE_HIBERNATE":
            reason = "Подготовка к гибернации ПК"
        else:
            reason = "Пауза по запросу владельца"

    state = set_standby_state(True, mode=mode, reason=reason, user_note=user_note)
    
    tg_html = (
        f"⏸ <b>Пайплайн поставлен на ПАУЗУ</b>\n\n"
        f"🎯 <b>Режим:</b> {mode}\n"
        f"📝 <b>Причина:</b> <i>{reason}</i>\n\n"
        f"• Авто-перезагрузки страниц и авто-напоминания заморожены.\n"
        f"• Отправка новых контекстов приостановлена.\n"
        f"• Вы можете свободно общаться с ChatGPT или отправлять ПК в сон."
    )
    send_telegram(tg_html)
    return state


def resume_pipeline() -> dict:
    state = set_standby_state(False, mode="NORMAL", reason="Ручное возобновление работы владельцем")
    dur_sec = state.get("last_pause_duration_sec", 0)
    dur_min = round(dur_sec / 60, 1)

    tg_html = (
        f"▶️ <b>Пайплайн СНЯТ С ПАУЗЫ (возобновлён)</b>\n\n"
        f"⏱ <b>Время на паузе:</b> {dur_min} мин ({dur_sec} сек).\n"
        f"⚡ Таймеры ожидания скорректированы, активирован 60-сек льготный период.\n"
        f"🔍 Выполняется поиск сформированных Action Packets во вкладках..."
    )
    send_telegram(tg_html)
    return state



def toggle_pipeline() -> dict:
    current = get_standby_state()
    if current.get("is_standby"):
        return resume_pipeline()
    else:
        return pause_pipeline(mode="MAN_IN_THE_MIDDLE")


def safe_sleep():
    """Pauses the pipeline cleanly, then puts Windows into Sleep mode."""
    print("\n[1/3] Постановка пайплайна на паузу (режим PRE_SLEEP)...")
    pause_pipeline(mode="PRE_SLEEP", reason="Штатный переход ПК в спящий режим")
    print("[2/3] Пауза зафиксирована. Отправка уведомления в Telegram...")
    time.sleep(1.5)
    print("[3/3] Перевод операционной системы в спящий режим...")
    cmd = [
        "powershell", "-NoProfile", "-Command",
        "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)"
    ]
    subprocess.run(cmd)


def safe_hibernate():
    """Pauses the pipeline cleanly, then puts Windows into Hibernate mode."""
    print("\n[1/3] Постановка пайплайна на паузу (режим PRE_HIBERNATE)...")
    pause_pipeline(mode="PRE_HIBERNATE", reason="Штатный переход ПК в гибернацию")
    print("[2/3] Пауза зафиксирована. Отправка уведомления в Telegram...")
    time.sleep(1.5)
    print("[3/3] Перевод операционной системы в режим гибернации...")
    subprocess.run(["shutdown.exe", "/h"])


def format_duration(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds} сек"
    mins = seconds // 60
    secs = seconds % 60
    if mins < 60:
        return f"{mins} мин {secs} сек"
    hours = mins // 60
    mins = mins % 60
    return f"{hours} ч {mins} мин"


def render_dashboard():
    """Renders real-time visual dashboard in console."""
    os.system("cls" if os.name == "nt" else "clear")
    st = get_standby_state()
    bridge = get_bridge_process_status()
    projs = get_projects_summary()

    is_paused = st.get("is_standby", False)
    mode = st.get("mode", "NORMAL")
    reason = st.get("reason", "")
    paused_at = st.get("paused_at_utc")

    pause_dur_str = "-"
    if is_paused and paused_at:
        try:
            p_dt = datetime.fromisoformat(paused_at.replace("Z", "+00:00"))
            cur_sec = int((datetime.now(timezone.utc) - p_dt).total_seconds())
            pause_dur_str = format_duration(max(0, cur_sec))
        except Exception:
            pass
    elif not is_paused:
        last_dur = st.get("last_pause_duration_sec", 0)
        pause_dur_str = f"Предыдущая пауза: {format_duration(last_dur)}"

    print("================================================================================")
    print("           AGENTIC PIPELINE v1.2.27 — ПАНЕЛЬ УПРАВЛЕНИЯ ПАУЗОЙ И СНОМ           ")
    print("================================================================================")
    print()
    if is_paused:
        print(f"  СТАТУС ПАЙПЛАЙНА:   [ ⏸  НА ПАУЗЕ ]")
        print(f"  Режим паузы:        {mode}")
        print(f"  Причина:            {reason}")
        print(f"  Время на паузе:     {pause_dur_str}")
    else:
        print(f"  СТАТУС ПАЙПЛАЙНА:   [ 🟢  АКТИВЕН / В РАБОТЕ ]")
        print(f"  Режим:              Полная автономная синхронизация (Pull + Push)")
        print(f"  История:            {pause_dur_str}")

    print()
    if bridge.get("running"):
        print(f"  Служба Bridge:      🟢 РАБОТАЕТ (PID: {bridge.get('pid')})")
    else:
        print(f"  Служба Bridge:      ⚪ НЕ ЗАПУЩЕНА (запустите: node companion_bridge.js watch)")

    print()
    print("  Состояние компаньонов в браузере:")
    for pkey, pdata in projs.items():
        name = "H10 Athlete Cardio Lab" if pkey == "h10" else "Vitalis"
        print(f"    • {name:<24}: статус [{pdata['state']}], пакет: {pdata['last_packet']}")

    print()
    print("--------------------------------------------------------------------------------")
    print("  [1] ⏸  Поставить на ПАУЗУ (Man-in-the-Middle / ручной диалог с ChatGPT)")
    print("  [2] ▶️  СНЯТЬ С ПАУЗЫ / Возобновить работу (с калибровкой таймеров)")
    print("  [3] 🔄  Переключить статус (Toggle Pause / Resume)")
    print("  [4] 🌙  Безопасный СПЯЩИЙ РЕЖИМ ПК (Пауза + Сон)")
    print("  [5] ❄️  Безопасная ГИБЕРНАЦИЯ ПК (Пауза + Гибернация)")
    print("  [6] 🔍  Обновить данные экрана")
    print("  [0] 🚪  Выход")
    print("--------------------------------------------------------------------------------")


def run_interactive_menu():
    while True:
        render_dashboard()
        try:
            choice = input("  Выберите действие [0-6]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nВыход.")
            break

        if choice in ("0", "q", "exit"):
            break
        elif choice == "1":
            print("\nПостановка на паузу...")
            pause_pipeline(mode="MAN_IN_THE_MIDDLE")
            print("Готово! Пайплайн на паузе. Вы можете вести ручной диалог в ChatGPT.")
            time.sleep(1.5)
        elif choice == "2":
            print("\nВозобновление работы...")
            resume_pipeline()
            print("Готово! Пайплайн возобновлён. Таймеры откалиброваны, поиск пакетов активен.")
            time.sleep(1.5)
        elif choice == "3":
            print("\nПереключение статуса...")
            toggle_pipeline()
            time.sleep(1.5)
        elif choice == "4":
            confirm = input("Подтвердите переход в спящий режим (Y/N, Enter = Y): ").strip().lower()
            if confirm in ("", "y", "yes", "д", "да"):
                safe_sleep()
                time.sleep(1)
        elif choice == "5":
            confirm = input("Подтвердите переход в режим гибернации (Y/N): ").strip().lower()
            if confirm in ("y", "yes", "д", "да"):
                safe_hibernate()
                time.sleep(1)
        elif choice == "6":
            continue
        else:
            print("Неверный ввод, повторите выбор.")
            time.sleep(1)


def main():
    if len(sys.argv) > 1:
        arg = sys.argv[1].lower()
        if arg in ("--pause", "-p", "pause"):
            reason = sys.argv[2] if len(sys.argv) > 2 else ""
            res = pause_pipeline(mode="MAN_IN_THE_MIDDLE", reason=reason)
            print("OK:", json.dumps(res, ensure_ascii=False, indent=2))
        elif arg in ("--resume", "-r", "resume"):
            res = resume_pipeline()
            print("OK:", json.dumps(res, ensure_ascii=False, indent=2))
        elif arg in ("--toggle", "-t", "toggle"):
            res = toggle_pipeline()
            print("OK:", json.dumps(res, ensure_ascii=False, indent=2))
        elif arg in ("--sleep", "sleep"):
            safe_sleep()
        elif arg in ("--hibernate", "hibernate"):
            safe_hibernate()
        elif arg in ("--status", "status", "-s"):
            st = get_standby_state()
            bridge = get_bridge_process_status()
            print(json.dumps({"standby": st, "bridge": bridge, "projects": get_projects_summary()}, ensure_ascii=False, indent=2))
        elif arg in ("--menu", "menu"):
            run_interactive_menu()
        else:
            print(f"Неизвестный аргумент: {arg}")
            print("Допустимо: --pause, --resume, --toggle, --sleep, --hibernate, --status, --menu")
    else:
        run_interactive_menu()


if __name__ == "__main__":
    main()
