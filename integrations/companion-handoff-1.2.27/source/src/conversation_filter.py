#!/usr/bin/env python3
"""
conversation_filter.py - Dynamic Conversation & Project Filter for Antigravity Handoffs

Allows the owner to specify exact conversation IDs and/or projects to include or exclude
from automatic LATEST_CONTEXT.zip generation and clipboard copying.

Configuration sources:
1. conversations.txt in the companion-handoff root directory
2. handoff.config.json under 'conversation_filter'
"""

import os
import json
from typing import Dict, Set, Tuple, List, Optional

def load_conversation_filter(base_dir: Optional[str] = None) -> Dict:
    """
    Loads conversation filtering rules from conversations.txt and handoff.config.json.
    """
    base_dir = base_dir or r"C:\Scripts\AntigravityProjects\companion-handoff"
    
    txt_candidates = [
        os.path.join(base_dir, "conversations.txt"),
        os.path.join(base_dir, "config", "conversations.txt"),
        os.path.expanduser("~/.agentic-pipeline/conversations.txt"),
    ]
    
    cfg_path = os.path.join(base_dir, "handoff.config.json")
    
    allowed_ids: Set[str] = set()
    denied_ids: Set[str] = set()
    allowed_projects: Set[str] = set()
    denied_projects: Set[str] = set()
    has_explicit_allows = False
    source_file = None

    # 1. Read plain-text conversations.txt
    for txt_path in txt_candidates:
        if os.path.exists(txt_path):
            source_file = txt_path
            try:
                with open(txt_path, "r", encoding="utf-8-sig") as f:
                    for line in f:
                        # Strip comments and extra spaces
                        raw = line.split("#")[0].split("//")[0].split(";")[0].strip()
                        if not raw:
                            continue
                        if raw == "*":
                            continue
                        
                        # Deny rule (! or - prefix)
                        if raw.startswith("!") or raw.startswith("-"):
                            rule = raw[1:].strip().lower()
                            if rule.startswith("project:") or rule.startswith("@"):
                                proj_name = rule.split(":", 1)[-1].lstrip("@").strip()
                                if proj_name:
                                    denied_projects.add(proj_name)
                            elif rule:
                                denied_ids.add(rule)
                        # Allow rule
                        else:
                            rule = raw.lower()
                            if rule.startswith("project:") or rule.startswith("@"):
                                proj_name = rule.split(":", 1)[-1].lstrip("@").strip()
                                if proj_name:
                                    allowed_projects.add(proj_name)
                                    has_explicit_allows = True
                            elif rule:
                                allowed_ids.add(rule)
                                has_explicit_allows = True
                break
            except Exception:
                pass

    # 2. Read handoff.config.json if present
    if os.path.exists(cfg_path):
        try:
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                cfg = json.load(f)
                filt = cfg.get("conversation_filter", {})
                if isinstance(filt, dict):
                    for cid in filt.get("allowed_conversations", []):
                        if cid and isinstance(cid, str) and cid.strip():
                            allowed_ids.add(cid.strip().lower())
                            has_explicit_allows = True
                    for cid in filt.get("ignored_conversations", []):
                        if cid and isinstance(cid, str) and cid.strip():
                            denied_ids.add(cid.strip().lower())
                    for p in filt.get("allowed_projects", []):
                        if p and isinstance(p, str) and p.strip():
                            allowed_projects.add(p.strip().lower())
                            has_explicit_allows = True
                    for p in filt.get("ignored_projects", []):
                        if p and isinstance(p, str) and p.strip():
                            denied_projects.add(p.strip().lower())
                
                # Also check root-level legacy lists
                for cid in cfg.get("allowed_conversations", []):
                    if cid and isinstance(cid, str) and cid.strip():
                        allowed_ids.add(cid.strip().lower())
                        has_explicit_allows = True
                for cid in cfg.get("ignored_conversations", []):
                    if cid and isinstance(cid, str) and cid.strip():
                        denied_ids.add(cid.strip().lower())
        except Exception:
            pass

    return {
        "source_file": source_file,
        "allowed_ids": allowed_ids,
        "denied_ids": denied_ids,
        "allowed_projects": allowed_projects,
        "denied_projects": denied_projects,
        "has_explicit_allows": has_explicit_allows,
    }

def is_conversation_allowed(
    conv_id: Optional[str],
    workspace_paths: Optional[List[str]] = None,
    filter_rules: Optional[Dict] = None,
    base_dir: Optional[str] = None,
) -> Tuple[bool, str]:
    """
    Evaluates whether a conversation ID and its workspace should trigger handoffs.
    
    Returns:
        (True, "allowed") or (False, "reason_for_exclusion")
    """
    if filter_rules is None:
        filter_rules = load_conversation_filter(base_dir)
        
    cid_norm = (conv_id or "").strip().lower()
    
    # Normalize workspace folder names and full paths
    ws_names = []
    if workspace_paths:
        for w in workspace_paths:
            if isinstance(w, str) and w.strip():
                clean_w = w.strip().replace("\\", "/").rstrip("/").lower()
                ws_names.append(clean_w)
                ws_names.append(os.path.basename(clean_w))

    # 1. Check explicit Denylist by conversation ID
    for denied in filter_rules.get("denied_ids", []):
        if cid_norm and (cid_norm == denied or cid_norm.startswith(denied)):
            return False, f"conversation_id_denied: {denied}"
            
    # 2. Check explicit Denylist by project name/path
    for denied_proj in filter_rules.get("denied_projects", []):
        for ws in ws_names:
            if denied_proj in ws:
                return False, f"project_denied: {denied_proj}"

    # 3. If explicit allowlist is configured, conversation or project must match
    if filter_rules.get("has_explicit_allows"):
        id_matched = any(
            cid_norm and (cid_norm == allowed or cid_norm.startswith(allowed))
            for allowed in filter_rules.get("allowed_ids", [])
        )
        proj_matched = any(
            any(allowed_p in ws for ws in ws_names)
            for allowed_p in filter_rules.get("allowed_projects", [])
        )
        
        if not id_matched and not proj_matched:
            return False, "not_in_allowed_conversations_list"

    return True, "allowed"


if __name__ == "__main__":
    import sys
    base = r"C:\Scripts\AntigravityProjects\companion-handoff"
    rules = load_conversation_filter(base)
    
    print("=== Antigravity Companion Handoff Filter Status ===")
    print(f"Filter Source File:     {rules.get('source_file') or 'None (allowing all by default)'}")
    print(f"Explicit Allow Mode:    {rules.get('has_explicit_allows')}")
    print(f"Allowed Conversation IDs: {list(rules.get('allowed_ids', []))}")
    print(f"Denied Conversation IDs:  {list(rules.get('denied_ids', []))}")
    print(f"Allowed Projects:       {list(rules.get('allowed_projects', []))}")
    print(f"Denied Projects:        {list(rules.get('denied_projects', []))}")
    
    if len(sys.argv) > 1:
        test_id = sys.argv[1]
        test_ws = [sys.argv[2]] if len(sys.argv) > 2 else []
        allowed, reason = is_conversation_allowed(test_id, test_ws, rules)
        print(f"\nTest Result for '{test_id}': Allowed={allowed} (Reason: {reason})")
