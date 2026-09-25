#!/usr/bin/env python3
"""
sync_agent_directives.py - Automatic Directive Synchronizer for Agentic Pipeline

Propagates the master "Top 10 Operational & Performance Directives" from
Agentic Pipeline/AGENTS.md to all companion projects registered in companion_bridge_config.json.
Guarantees zero instruction drift across isolated workspace roots.
"""

import os
import sys
import json
import re
from pathlib import Path

CENTRAL_DIR = Path(__file__).resolve().parent.parent
CENTRAL_AGENTS_MD = CENTRAL_DIR / "AGENTS.md"
CONFIG_PATH = Path(r"C:\Users\Администратор\.gemini\antigravity\companion_bridge_config.json")

def extract_top10_directives(text: str) -> str:
    """Extracts section 3 (Top 10 Operational Directives) from central AGENTS.md."""
    match = re.search(r'(###?\s*\d*\.?\s*Top 10 Operational & Performance Directives.*?)(?=\n##|\Z)', text, re.DOTALL | re.IGNORECASE)
    if match:
        return match.group(1).strip()
    return ""

def sync_directives():
    if not CENTRAL_AGENTS_MD.is_file():
        print(f"[ERROR] Central AGENTS.md not found at {CENTRAL_AGENTS_MD}")
        return False

    central_text = CENTRAL_AGENTS_MD.read_text(encoding="utf-8")
    directives = extract_top10_directives(central_text)
    if not directives:
        print("[WARN] Could not locate Top 10 Directives section in central AGENTS.md")
        return False

    if not CONFIG_PATH.is_file():
        print(f"[ERROR] companion_bridge_config.json not found at {CONFIG_PATH}")
        return False

    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    companions = cfg.get("browser", {}).get("companions", {})

    synced = []
    for key, comp in companions.items():
        proj_path_str = comp.get("projectPath")
        if not proj_path_str:
            continue
        proj_path = Path(proj_path_str)
        target_agents_md = proj_path / "AGENTS.md"
        if not target_agents_md.is_file():
            print(f"[{key}] AGENTS.md not found in {proj_path}, skipping.")
            continue

        target_text = target_agents_md.read_text(encoding="utf-8")
        
        # Check if already up-to-date with all directives including visualqa
        if "ANTI-MICRO-SLICING PROTOCOL (STRICT)" in target_text and "MANDATORY PROCESS HYGIENE & ZERO-ZOMBIE PROTOCOL" in target_text and "PERIODIC /visualqa & VISUAL EVIDENCE AUDIT" in target_text:
            print(f"[{key}] Already contains up-to-date Top 10 directives: {target_agents_md}")
            synced.append(str(target_agents_md))
            continue

        # Replace or append Section 5
        sec5_pattern = re.compile(r'## 5\..*', re.DOTALL)
        if sec5_pattern.search(target_text):
            new_target_text = sec5_pattern.sub(f"## 5. Top 10 Performance & Speed Directives (Strict Enforcement)\n\n{directives}\n", target_text)
        else:
            new_target_text = target_text.rstrip() + f"\n\n## 5. Top 10 Performance & Speed Directives (Strict Enforcement)\n\n{directives}\n"

        target_agents_md.write_text(new_target_text, encoding="utf-8")
        print(f"[{key}] Successfully synchronized Top 10 Directives into {target_agents_md}")
        synced.append(str(target_agents_md))

    return synced

if __name__ == "__main__":
    res = sync_directives()
    print(f"Directives synchronized across {len(res) if res else 0} companion projects.")
