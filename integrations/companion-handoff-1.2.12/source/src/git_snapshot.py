#!/usr/bin/env python3
"""
git_snapshot.py - Git Snapshot Capture for Auto Context Handoff v4.3.4.
"""

import os
import subprocess
import json
import datetime
from typing import Dict, Any, Union

def run_git_command(args: list[str], cwd: str) -> str:
    """Run a git command and return its stdout, or empty string on failure."""
    try:
        no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        result = subprocess.run(
            ['git'] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding='utf-8',
            timeout=10,
            check=False,
            creationflags=no_window
        )
        if result.returncode == 0:
            return result.stdout
    except (subprocess.SubprocessError, OSError):
        pass
    return ""

def capture_git_snapshot(git_root: str, root_id: str) -> Dict[str, Any]:
    """Capture complete Git state for a root."""
    if not os.path.exists(git_root):
        return {}
        
    git_dir_path = os.path.join(git_root, '.git')
    is_linked_worktree = os.path.isfile(git_dir_path)
    
    try:
        no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        status_res = subprocess.run(
            ['git', 'status', '--porcelain'],
            cwd=git_root,
            capture_output=True,
            text=True,
            encoding='utf-8',
            timeout=10,
            creationflags=no_window
        )
        if status_res.returncode == 0:
            status_porcelain = status_res.stdout
            git_clean = (len(status_porcelain.strip()) == 0)
        else:
            git_clean = 'unknown'
            status_porcelain = ""
    except Exception:
        git_clean = 'unknown'
        status_porcelain = ""
        
    branch = run_git_command(['rev-parse', '--abbrev-ref', 'HEAD'], git_root).strip()
    head = run_git_command(['rev-parse', 'HEAD'], git_root).strip()
    
    common_dir = run_git_command(['rev-parse', '--git-common-dir'], git_root).strip()
    if common_dir and not os.path.isabs(common_dir):
        common_dir = os.path.normpath(os.path.join(git_root, common_dir))
        
    tracked_diff = run_git_command(['diff'], git_root)
    staged_diff = run_git_command(['diff', '--cached'], git_root)
    diff_stat = run_git_command(['diff', '--stat'], git_root)
    
    untracked_out = run_git_command(['ls-files', '--others', '--exclude-standard'], git_root)
    untracked = untracked_out.splitlines() if untracked_out else []
    
    recent_commits = run_git_command(['log', '-10', '--oneline'], git_root)
    
    worktrees_out = run_git_command(['worktree', 'list'], git_root)
    worktrees = [line.strip() for line in worktrees_out.splitlines() if line.strip()]
            
    root_info = {
        "path": git_root,
        "branch": branch,
        "head": head,
        "git_clean": git_clean,
        "is_linked_worktree": is_linked_worktree,
        "common_git_dir": common_dir,
        "captured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()
    }
    
    return {
        "ROOT_INFO": root_info,
        "STATUS_PORCELAIN": status_porcelain,
        "TRACKED_DIFF": tracked_diff,
        "STAGED_DIFF": staged_diff,
        "DIFF_STAT": diff_stat,
        "UNTRACKED": untracked,
        "RECENT_COMMITS": recent_commits,
        "WORKTREES": worktrees
    }

def get_zip_entries(git_root: str, root_id: str) -> Dict[str, bytes]:
    """Returns dict mapping ZIP member paths to bytes for the snapshot."""
    snapshot = capture_git_snapshot(git_root, root_id)
    if not snapshot:
        return {}
        
    entries = {}
    prefix = f"git/{root_id}/"
    
    entries[prefix + "ROOT_INFO.json"] = json.dumps(snapshot["ROOT_INFO"], ensure_ascii=False, indent=2).encode('utf-8-sig')
    entries[prefix + "STATUS_PORCELAIN.txt"] = snapshot["STATUS_PORCELAIN"].encode('utf-8')
    entries[prefix + "TRACKED_DIFF.patch"] = snapshot["TRACKED_DIFF"].encode('utf-8')
    entries[prefix + "STAGED_DIFF.patch"] = snapshot["STAGED_DIFF"].encode('utf-8')
    entries[prefix + "DIFF_STAT.txt"] = snapshot["DIFF_STAT"].encode('utf-8')
    entries[prefix + "UNTRACKED.json"] = json.dumps(snapshot["UNTRACKED"], ensure_ascii=False, indent=2).encode('utf-8-sig')
    entries[prefix + "RECENT_COMMITS.txt"] = snapshot["RECENT_COMMITS"].encode('utf-8')
    entries[prefix + "WORKTREES.json"] = json.dumps(snapshot["WORKTREES"], ensure_ascii=False, indent=2).encode('utf-8-sig')
    
    return entries
