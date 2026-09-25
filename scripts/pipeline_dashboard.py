#!/usr/bin/env python3
"""
Pipeline Cycles Unified Dashboard CLI
Displays live real-time status across all active projects:
[Проект] | [Фаза / Цель] | [Статус Агента] | [Статус Компаньона] | [Текущее препятствие / Таймер]
"""

import os
import sys
import json
import time
import datetime as dt
from pathlib import Path

# Paths
CONFIG_PATH = Path(os.path.expandvars(r"%USERPROFILE%\.gemini\antigravity\companion_bridge_config.json"))
BRAIN_PATH = Path(os.path.expandvars(r"%USERPROFILE%\.gemini\antigravity\brain"))
SEEN_PACKETS_PATH = Path(os.path.expandvars(r"%USERPROFILE%\.gemini\antigravity\companion_seen_packets.json"))
STANDBY_PATH = Path(os.path.expandvars(r"%USERPROFILE%\.agentic-pipeline\action-bridge\STANDBY_STATE.json"))

def get_transcript_last_step(cid: str) -> dict:
    if not cid:
        return {}
    p = BRAIN_PATH / cid / ".system_generated" / "logs" / "transcript.jsonl"
    if not p.is_file():
        return {}
    try:
        size = p.stat().st_size
        read_bytes = min(size, 65536)
        with open(p, "rb") as f:
            f.seek(size - read_bytes)
            lines = f.read().decode("utf-8", errors="ignore").splitlines()
        for line in reversed(lines):
            line = line.strip()
            if line:
                try:
                    return json.loads(line)
                except Exception:
                    pass
    except Exception:
        pass
    return {}

def format_relative_time(timestamp_str: str) -> str:
    if not timestamp_str:
        return "неизвестно"
    try:
        t = dt.datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        now = dt.datetime.now(dt.timezone.utc)
        sec = int((now - t).total_seconds())
        if sec < 0:
            sec = 0
        if sec < 60:
            return f"{sec}с назад"
        elif sec < 3600:
            return f"{sec // 60}м {sec % 60}с назад"
        else:
            return f"{sec // 3600}ч {(sec % 3600) // 60}м назад"
    except Exception:
        return timestamp_str[:19]

def render_dashboard() -> str:
    if not CONFIG_PATH.is_file():
        return "ERROR: companion_bridge_config.json not found."
    
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
        
    seen = {}
    if SEEN_PACKETS_PATH.is_file():
        try:
            with open(SEEN_PACKETS_PATH, "r", encoding="utf-8") as f:
                seen = json.load(f)
        except Exception:
            pass

    standby = {"is_standby": False, "mode": "NORMAL"}
    if STANDBY_PATH.is_file():
        try:
            with open(STANDBY_PATH, "r", encoding="utf-8") as f:
                standby = json.load(f)
        except Exception:
            pass

    companions = cfg.get("browser", {}).get("companions", {})
    
    out = []
    out.append("=" * 110)
    now_str = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    sb_status = "⏸ STANDBY / ПАУЗА" if standby.get("is_standby") else "🟢 ACTIVE / В РАБОТЕ"
    out.append(f"  ТАБЛО СОСТОЯНИЯ ЦИКЛОВ АГЕНТОВ (AGENTIC PIPELINE) — {now_str}")
    out.append(f"  Общий режим: {sb_status} (Режим: {standby.get('mode', 'NORMAL')})")
    out.append("=" * 110)
    
    for key, comp in companions.items():
        name = comp.get("name", key)
        cid = comp.get("antigravityConversationId", "")
        proj_path = Path(comp.get("projectPath", ""))
        
        # Read .agy files
        wi_file = proj_path / ".agy" / "WORK_ITEM.json"
        na_file = proj_path / ".agy" / "NEXT_ACTION.json"
        hs_file = proj_path / ".agy" / "RUNTIME_HANDSHAKE.json"
        
        goal = "Не инициализирован"
        work_item_id = "-"
        if wi_file.is_file():
            try:
                with open(wi_file, "r", encoding="utf-8") as f:
                    wi_data = json.load(f)
                    goal = wi_data.get("goal", goal)
                    work_item_id = wi_data.get("work_item_id", work_item_id)
            except Exception:
                pass
                
        route = "-"
        auto_continue = False
        owner_decision_req = False
        owner_reason = ""
        if na_file.is_file():
            try:
                with open(na_file, "r", encoding="utf-8") as f:
                    na_data = json.load(f)
                    route = na_data.get("route") or "null (завершено/ожидает)"
                    auto_continue = na_data.get("auto_continue", False)
                    owner_decision_req = na_data.get("owner_decision_required", False)
                    owner_reason = na_data.get("owner_decision_reason", "")
            except Exception:
                pass

        # Check transcript
        last_step = get_transcript_last_step(cid)
        step_idx = last_step.get("step_index", "?")
        step_time = last_step.get("created_at", "")
        step_status = last_step.get("status", "?")
        step_content = str(last_step.get("content", ""))[:80].replace("\n", " ")
        rel_time = format_relative_time(step_time)
        
        # Check companion state
        p_seen = seen.get(key, {})
        turn_state = p_seen.get("turnState", "READY_FOR_CONTEXT")
        comp_packet = p_seen.get("fileName") or p_seen.get("lastPacketId") or "-"

        # Obstacle
        obstacle = "Нет (автономное движение)"
        if owner_decision_req:
            short_r = (owner_reason[:65] + "...") if len(owner_reason) > 65 else owner_reason
            obstacle = f"🛑 РЕШЕНИЕ ВЛАДЕЛЬЦА: {short_r}"
        elif turn_state in ("WAITING_FOR_RESPONSE", "AWAITING_COMPANION_PACKET"):
            obstacle = "⏳ Ожидание ответа Компаньона (ChatGPT генерирует)"
        elif not auto_continue and route == "null (завершено/ожидает)":
            obstacle = "🏁 Фаза завершена, ожидает следующего экшн-пакета"
        elif standby.get("is_standby"):
            obstacle = f"⏸ Пауза пайплайна ({standby.get('reason', '')})"

        out.append(f"\n▶ ПРОЕКТ: {name.upper()} (ключ: {key})")
        out.append(f"  ├ Цель/Фаза:        {goal}")
        out.append(f"  ├ Рабочий элемент:  {work_item_id}")
        out.append(f"  ├ Статус Агента:    Шаг {step_idx} [{step_status}] ({rel_time}) | Маршрут: {route}")
        out.append(f"  ├ Последнее действие: «{step_content}»")
        out.append(f"  ├ Компаньон:        {turn_state} | Пакет: {comp_packet}")
        out.append(f"  └ Препятствие:      {obstacle}")

    out.append("\n" + "=" * 110)
    return "\n".join(out)

if __name__ == "__main__":
    print(render_dashboard())
