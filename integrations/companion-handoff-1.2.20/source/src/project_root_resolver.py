#!/usr/bin/env python3
"""
project_root_resolver.py - Project Root Resolution for Auto Context Handoff v4.3.4.
"""

import os
import subprocess
from typing import List, Dict, Optional, Set

def normalize_path(p: str) -> str:
    """Strip quotes/whitespace, normalize separators, capitalize drive letter."""
    if not p:
        return ""
    p = p.strip(' "\'')
    p = os.path.normpath(p)
    if len(p) >= 2 and p[1] == ':' and p[0].isalpha():
        p = p[0].upper() + p[1:]
    return p

def get_git_root(path: str) -> Optional[str]:
    """Walk up to find .git (file or directory), support linked worktrees."""
    path = normalize_path(path)
    if not os.path.isdir(path):
        path = os.path.dirname(path)
        
    while True:
        git_path = os.path.join(path, '.git')
        if os.path.exists(git_path):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent

def get_git_common_dir(path: str) -> Optional[str]:
    """Run `git rev-parse --git-common-dir` to find shared git dir."""
    path = normalize_path(path)
    if not os.path.isdir(path):
        path = os.path.dirname(path)
    try:
        no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        result = subprocess.run(
            ['git', 'rev-parse', '--git-common-dir'],
            cwd=path,
            capture_output=True,
            text=True,
            encoding='utf-8',
            timeout=10,
            check=True,
            creationflags=no_window
        )
        common_dir = result.stdout.strip()
        if not os.path.isabs(common_dir):
            common_dir = os.path.normpath(os.path.join(path, common_dir))
        return normalize_path(common_dir)
    except (subprocess.SubprocessError, OSError):
        return None

def find_project_root(path: str) -> Optional[str]:
    """
    Find nearest parent with project markers: pyproject.toml, package.json, requirements.txt, 
    src/, install/, schemas/, README.md, handoff.config.json.
    MUST NOT return ...\\src if parent has markers.
    """
    path = normalize_path(path)
    if not os.path.isdir(path):
        path = os.path.dirname(path)
        
    markers: Set[str] = {'pyproject.toml', 'package.json', 'requirements.txt', 'src', 'install', 'schemas', 'README.md', 'handoff.config.json'}
    
    candidate = None
    current = path
    while True:
        try:
            items = set(os.listdir(current))
            if items.intersection(markers):
                candidate = current
        except OSError:
            pass
            
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
        
    # Prevent returning a 'src' directory if its parent is the actual root
    if candidate and os.path.basename(candidate).lower() == 'src':
        parent = os.path.dirname(candidate)
        try:
            parent_items = set(os.listdir(parent))
            if parent_items.intersection(markers - {'src'}):
                candidate = parent
        except OSError:
            pass
            
    return candidate

def classify_roots(touched_paths: List[str], launch_workspace: str, write_operations: List[str]) -> Dict[str, str]:
    """
    Classify roots into a dict with: launch_workspace, primary_implementation_root, 
    additional_implementation_roots, runtime_root, artifact_roots, supporting_roots.
    Scores by: write operations > owner objective > current diff > task outputs > launch workspace as fallback.
    """
    launch_workspace = normalize_path(launch_workspace)
    
    root_scores: Dict[str, int] = {}
    
    for path in touched_paths:
        root = find_project_root(path) or get_git_root(path) or os.path.dirname(normalize_path(path))
        root_scores[root] = root_scores.get(root, 0) + 1
        
    for path in write_operations:
        root = find_project_root(path) or get_git_root(path) or os.path.dirname(normalize_path(path))
        root_scores[root] = root_scores.get(root, 0) + 5
        
    if launch_workspace not in root_scores:
        root_scores[launch_workspace] = 0
        
    sorted_roots = sorted(root_scores.keys(), key=lambda r: root_scores[r], reverse=True)
    
    primary = sorted_roots[0] if sorted_roots else launch_workspace
    additional = [r for r in sorted_roots if r != primary and r != launch_workspace]
    
    return {
        "launch_workspace": launch_workspace,
        "primary_implementation_root": primary,
        "additional_implementation_roots": ",".join(additional),
        "runtime_root": launch_workspace,
        "logical_project_slug": os.path.basename(os.path.normpath(launch_workspace)) if launch_workspace else "",
        "result_worktree_slug": os.path.basename(os.path.normpath(primary)) if primary else "",
        "artifact_roots": "",
        "supporting_roots": ""
    }

def is_same_repo(r1: str, r2: str) -> bool:
    """Compare git repos tolerantly."""
    r1_norm = normalize_path(r1)
    r2_norm = normalize_path(r2)
    if r1_norm == r2_norm:
        return True
    
    r1_git = get_git_root(r1_norm)
    r2_git = get_git_root(r2_norm)
    
    if r1_git and r2_git and r1_git == r2_git:
        return True
        
    c1 = get_git_common_dir(r1_norm) if r1_git else None
    c2 = get_git_common_dir(r2_norm) if r2_git else None
    
    if c1 and c2 and c1 == c2:
        return True
        
    return False
