#!/usr/bin/env python3
"""
authority_collector.py - Authority Collection for Auto Context Handoff v4.3.4.
"""

import os
import json
from typing import List, Dict, Any, Optional

AUTHORITY_FILES = [
    "RUN_RESULT.json",
    "VERIFICATION_RECEIPT.json",
    "AUDIT_RESULT.json",
    "PHASE_RESULT.json",
    "PHASE_STATUS.json",
    "RUNTIME_HANDSHAKE.json",
    "INSTALLATION_MANIFEST.json",
    "COMMAND_INVENTORY.json",
    "TARGET_RUNTIME_BASELINE.json",
    "PROGRESS_POLICY.json",
    "PROGRESS_STATE.json",
    "NEXT_ACTION.json",
    "CANDIDATE_MANIFEST.json",
    "CANDIDATE_MANIFEST_STATUS.json",
    "ACTION_PACKET_RECEIPT.json"
]

SEARCH_SUBDIRS = [
    ".agy",
    ".agents",
    ".artifacts",
    "artifacts",
    "reports",
    "validation"
]

def safe_read_json(filepath: str) -> Optional[Dict[str, Any]]:
    """Reads JSON with UTF-8-sig to handle BOM and ensure safe reading."""
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None

def normalize_status(raw_status: str) -> str:
    """Normalizes various status strings into standard ones."""
    if not isinstance(raw_status, str):
        return 'unknown'
    status = raw_status.lower().strip()
    if status in ['accepted', 'passed', 'completed']:
        return 'accepted'
    elif status in ['blocked', 'failed']:
        return 'blocked'
    else:
        return 'unknown'

def discover_authorities(search_roots: List[str], artifact_dir: Optional[str] = None) -> List[Dict[str, Any]]:
    """Scans search roots, SEARCH_SUBDIRS, and artifact_dir for authority candidates."""
    candidates = []
    
    dirs_to_search = []
    for root in search_roots:
        if os.path.exists(root):
            dirs_to_search.append(root)
            for subdir in SEARCH_SUBDIRS:
                sub_path = os.path.join(root, subdir)
                if os.path.exists(sub_path):
                    dirs_to_search.append(sub_path)
    
    if artifact_dir and os.path.exists(artifact_dir):
        dirs_to_search.append(artifact_dir)

    for d in set(os.path.normpath(x) for x in dirs_to_search):
        try:
            for item in os.listdir(d):
                if item in AUTHORITY_FILES:
                    filepath = os.path.join(d, item)
                    data = safe_read_json(filepath)
                    valid = data is not None and isinstance(data, dict)
                    candidates.append({
                        "path": filepath,
                        "filename": item,
                        "root": d,
                        "modified_at": os.path.getmtime(filepath) if os.path.exists(filepath) else 0,
                        "schema_valid": valid,
                        "data": data if valid else {}
                    })
        except OSError:
            pass

    return candidates

def _get_field(data: Dict[str, Any], aliases: List[str]) -> Any:
    for alias in aliases:
        if alias in data:
            return data[alias]
    return None

def score_authority(candidate: Dict[str, Any], work_item_id: Optional[str] = None, branch: Optional[str] = None, head: Optional[str] = None) -> int:
    """Scores an authority candidate based on freshness, matching fields, and validity."""
    if not candidate.get("schema_valid"):
        return 0

    score = 10  # Base score for valid schema
    data = candidate.get("data", {})
    filename = candidate.get("filename", "")

    # Common authority aliases used by adopted and new projects.
    item_aliases = ["work_item", "work_item_id", "task_id", "target_work_item"]
    
    file_work_item = _get_field(data, item_aliases)
    
    if work_item_id and file_work_item == work_item_id:
        score += 30
    
    file_branch = data.get("branch")
    if branch and file_branch == branch:
        score += 20
        
    file_head = data.get("head") or data.get("commit")
    if head and file_head == head:
        score += 20
        
    return score

def select_best_authority(candidates: List[Dict[str, Any]], work_item_id: Optional[str] = None, branch: Optional[str] = None, head: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """Selects the highest scoring authority candidate."""
    best = None
    best_score = -1
    best_time = -1

    for c in candidates:
        score = score_authority(c, work_item_id, branch, head)
        if score > 0:
            mtime = c.get("modified_at", 0)
            if score > best_score or (score == best_score and mtime > best_time):
                best = c
                best_score = score
                best_time = mtime

    return best

def collect_and_select(search_roots: List[str], artifact_dir: Optional[str] = None, work_item_id: Optional[str] = None, branch: Optional[str] = None, head: Optional[str] = None) -> Dict[str, Any]:
    """Discovers, scores, and returns selected authorities with selection_reason."""
    candidates = discover_authorities(search_roots, artifact_dir)
    
    selected = {}
    grouped = {f: [] for f in AUTHORITY_FILES}
    for c in candidates:
        grouped[c["filename"]].append(c)
        
    for filename, group in grouped.items():
        if not group:
            continue
        best = select_best_authority(group, work_item_id, branch, head)
        if best:
            selected[filename] = {
                "path": best["path"],
                "data": best["data"],
                "selection_reason": "Highest score based on freshness and context match",
                "score": score_authority(best, work_item_id, branch, head)
            }
            
    return selected
