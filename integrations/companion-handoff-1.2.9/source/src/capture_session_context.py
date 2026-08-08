#!/usr/bin/env python3
"""
capture_session_context.py - Session context capture module for Auto Context Handoff v4.3.4.

Captures touched roots, touched files, SESSION_DELTA, tool/command traces,
relative safe source snapshots (no traversal paths), and multi-root write detection.
"""

import os
import json
import re
import glob
import subprocess
import hashlib
from datetime import timezone, datetime

def normalize_path(p):
    if not p:
        return ""
    p = str(p).strip(" \"'\t\r\n").rstrip(".,;\"'")
    p = os.path.normpath(p)
    if len(p) >= 2 and p[1] == ":":
        p = p[0].upper() + p[1:]
    return p

def get_git_root(path):
    if not path:
        return None
    curr = normalize_path(path)
    if os.path.isfile(curr):
        curr = os.path.dirname(curr)
    while curr and os.path.dirname(curr) != curr:
        if os.path.exists(os.path.join(curr, ".git")):
            return curr
        curr = os.path.dirname(curr)
    return None

def is_privacy_excluded(filepath, fail_closed_patterns=None):
    if not filepath:
        return True
    fname = os.path.basename(filepath)
    patterns = fail_closed_patterns or [
        ".env*", "*credentials*", "*token*", "*.pem", "*.key",
        "*.sqlite*", "conversations.db*", "*.db", "*.db-wal", "*.db-shm",
        "*raw_ecg*", "*raw_biometrics*"
    ]
    for pat in patterns:
        if re.match(re.escape(pat).replace(r"\*", ".*"), fname, re.IGNORECASE):
            return True
        if pat.lower() in filepath.lower():
            return True
    return False

def get_sha256(filepath_or_bytes):
    try:
        h = hashlib.sha256()
        if isinstance(filepath_or_bytes, bytes):
            h.update(filepath_or_bytes)
        elif isinstance(filepath_or_bytes, str) and os.path.exists(filepath_or_bytes):
            with open(filepath_or_bytes, "rb") as f:
                while chunk := f.read(65536):
                    h.update(chunk)
        else:
            h.update(str(filepath_or_bytes).encode("utf-8"))
        return h.hexdigest()
    except Exception:
        return None

class SessionContextCapturer:
    def __init__(self, stop_payload, transcript_path, privacy_config=None, prev_processed_line=0):
        self.stop_payload = stop_payload or {}
        self.transcript_path = transcript_path
        self.privacy_config = privacy_config or {}
        self.fail_closed_patterns = self.privacy_config.get("fail_closed_patterns", [])
        self.prev_processed_line = prev_processed_line

    def capture(self):
        ws_paths = [normalize_path(p) for p in self.stop_payload.get("workspacePaths", []) if p]
        launch_ws = ws_paths[0] if ws_paths else None

        touched_files = {}
        command_trace = []
        privacy_exclusions = []
        transcript_delta_lines = []
        tool_calls_delta = []
        last_owner_request = ""
        last_model_response = ""

        current_line_idx = 0

        if self.transcript_path and os.path.exists(self.transcript_path):
            with open(self.transcript_path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    current_line_idx += 1
                    if not line.strip():
                        continue
                    try:
                        record = json.loads(line)
                        stype = record.get("type", "")
                        tool_calls = record.get("tool_calls", []) or []
                        content = record.get("content", "")
                        ts = record.get("timestamp") or record.get("created_at", "")

                        if stype == "USER_INPUT" and content:
                            last_owner_request = content
                        if stype == "PLANNER_RESPONSE" and content and content.strip():
                            if len(content.strip()) > 30:
                                last_model_response = content

                        if current_line_idx > self.prev_processed_line:
                            transcript_delta_lines.append(line.strip())

                        # Parse tool calls
                        for tc in tool_calls:
                            tname = tc.get("name") or tc.get("toolName") or ""
                            args = tc.get("arguments") or tc.get("args") or tc.get("Arguments") or {}

                            if current_line_idx > self.prev_processed_line:
                                tool_calls_delta.append({
                                    "line": current_line_idx,
                                    "tool_name": tname,
                                    "arguments": args,
                                    "timestamp": ts,
                                })

                            # Resolve relative TargetFile using Cwd
                            tool_cwd = normalize_path(args.get("Cwd") or launch_ws or "")

                            path_keys = ["TargetFile", "AbsolutePath", "path", "file", "Target", "SearchPath", "Cwd"]
                            for pk in path_keys:
                                pval = args.get(pk)
                                if isinstance(pval, str) and len(pval) > 2:
                                    pval = pval.strip(" \"'\t\r\n").rstrip(".,;\"'")
                                    if not os.path.isabs(pval) and tool_cwd:
                                        pval = os.path.join(tool_cwd, pval)
                                    norm_p = normalize_path(pval)

                                    op = "viewed"
                                    if any(w in tname.lower() for w in ["write", "create", "replace", "edit", "patch"]):
                                        op = "edited"
                                    elif "replace" in tname.lower() or "edit" in tname.lower():
                                        op = "edited"
                                    elif "delete" in tname.lower() or "remove" in tname.lower():
                                        op = "deleted"
                                    elif "command" in tname.lower() or "run" in tname.lower():
                                        op = "executed"

                                    if norm_p not in touched_files:
                                        touched_files[norm_p] = {
                                            "path": norm_p,
                                            "operation": op,
                                            "first_line": current_line_idx,
                                            "timestamp": ts,
                                            "tool_name": tname,
                                        }
                                    else:
                                        if op in ["created", "edited", "deleted"]:
                                            touched_files[norm_p]["operation"] = op

                            # Command trace & path extraction inside command line
                            if "command" in tname.lower() or "run" in tname.lower():
                                cmd = args.get("CommandLine") or args.get("command") or args.get("Target") or ""
                                command_trace.append({
                                    "line": current_line_idx,
                                    "timestamp": ts,
                                    "tool_name": tname,
                                    "command": cmd,
                                    "cwd": tool_cwd,
                                })
                                # Extract paths inside command line
                                cmd_paths = re.findall(r"(?:[A-Za-z]:\\[^\"'\s]+|\b\./[^\"'\s]+)", cmd)
                                for cp in cmd_paths:
                                    if not os.path.isabs(cp) and tool_cwd:
                                        cp = os.path.join(tool_cwd, cp)
                                    norm_cp = normalize_path(cp)
                                    if norm_cp not in touched_files and os.path.exists(norm_cp):
                                        touched_files[norm_cp] = {
                                            "path": norm_cp,
                                            "operation": "executed",
                                            "first_line": current_line_idx,
                                            "timestamp": ts,
                                            "tool_name": tname,
                                        }

                        if content:
                            matches = re.findall(r"(?:Saved|Created|Edited|Viewed|Ran command|writing to|reading)\s+[\"']?([A-Za-z]:\\[^\"'\r\n]+)", content)
                            for m in matches:
                                norm_p = normalize_path(m)
                                if norm_p not in touched_files:
                                    touched_files[norm_p] = {
                                        "path": norm_p,
                                        "operation": "viewed",
                                        "first_line": current_line_idx,
                                        "timestamp": ts,
                                        "tool_name": "transcript_narrative",
                                    }
                    except Exception:
                        pass

        # Also add workspace paths themselves
        for wp in ws_paths:
            if wp and wp not in touched_files:
                touched_files[wp] = {
                    "path": wp,
                    "operation": "viewed",
                    "first_line": 0,
                    "timestamp": "",
                    "tool_name": "workspace_launch",
                }

        # Roots map & git info
        roots_map = {}
        for p, info in list(touched_files.items()):
            if is_privacy_excluded(p, self.fail_closed_patterns):
                privacy_exclusions.append(p)
                info["privacy_excluded"] = True

            exists = os.path.exists(p)
            info["exists"] = exists
            info["size_bytes"] = os.path.getsize(p) if exists and os.path.isfile(p) else 0
            info["sha256"] = get_sha256(p) if exists and os.path.isfile(p) else None

            groot = get_git_root(p)
            info["git_root"] = groot
            info["is_outside_launch_workspace"] = bool(launch_ws and not p.lower().startswith(launch_ws.lower()))

            r_key = groot or (p if os.path.isdir(p) else os.path.dirname(p))
            r_key = normalize_path(r_key)

            if r_key not in roots_map:
                roots_map[r_key] = {
                    "root_path": r_key,
                    "git_root": groot,
                    "is_launch_workspace": bool(launch_ws and r_key.lower() == launch_ws.lower()),
                    "operations": {},
                    "touched_file_count": 0,
                    "write_operation_count": 0,
                }

            r_entry = roots_map[r_key]
            op = info["operation"]
            r_entry["operations"][op] = r_entry["operations"].get(op, 0) + 1
            r_entry["touched_file_count"] += 1
            if op in ["created", "edited", "deleted"]:
                r_entry["write_operation_count"] += 1

        def _is_brain_dir(p):
            lp = p.lower().replace('/', '\\')
            return '\\.gemini\\antigravity\\brain\\' in lp or '\\antigravity\\brain\\' in lp

        code_impl_roots = [rk for rk, rinfo in roots_map.items() if rinfo["write_operation_count"] > 0 and not _is_brain_dir(rk)]
        all_impl_roots = [rk for rk, rinfo in roots_map.items() if rinfo["write_operation_count"] > 0]
        implementation_roots = code_impl_roots if code_impl_roots else all_impl_roots

        supporting_roots = [rk for rk, rinfo in roots_map.items() if rk not in implementation_roots]

        ext_impl_roots = [ir for ir in implementation_roots if launch_ws and ir.lower() != launch_ws.lower()]
        multi_root_task = (len(implementation_roots) > 1) or (len(ext_impl_roots) > 0)

        # Primary implementation root selection (highest write ops in code impl roots)
        primary_impl_root = None
        if code_impl_roots:
            sorted_impl = sorted(code_impl_roots, key=lambda r: roots_map[r]["write_operation_count"], reverse=True)
            primary_impl_root = sorted_impl[0]
        elif launch_ws:
            primary_impl_root = launch_ws
        elif implementation_roots:
            primary_impl_root = implementation_roots[0]

        uncaptured_external_write_root = False
        for ir in implementation_roots:
            if not os.path.exists(ir) and not _is_brain_dir(ir):
                uncaptured_external_write_root = True

        touched_roots_payload = {
            "launch_workspace": launch_ws,
            "primary_implementation_root": primary_impl_root,
            "multi_root_task": multi_root_task,
            "implementation_roots": implementation_roots,
            "supporting_roots": supporting_roots,
            "uncaptured_external_write_root": uncaptured_external_write_root,
            "roots": list(roots_map.values()),
        }

        touched_files_payload = {
            "file_count": len(touched_files),
            "files": list(touched_files.values()),
        }

        command_trace_payload = {
            "command_count": len(command_trace),
            "commands": command_trace,
        }

        # Source Snapshots relative to OWN implementation root (SAFE PATHS, NO TRAVERSAL ..)
        source_snapshots = {}
        missing_truncated_snapshots = []

        max_snap_size = self.privacy_config.get("max_snapshot_size_bytes", 500_000)

        for p, info in touched_files.items():
            if info.get("privacy_excluded"):
                continue
            if not info["exists"] or not os.path.isfile(p):
                continue

            # Find matching implementation root for p
            owning_root = None
            for ir in implementation_roots:
                if p.lower().startswith(ir.lower()):
                    owning_root = ir
                    break
            if not owning_root:
                owning_root = info.get("git_root") or launch_ws or os.path.dirname(p)

            owning_root = normalize_path(owning_root)

            # Build safe relative path WITHOUT '..' or drive prefix
            try:
                rel_path = os.path.relpath(p, owning_root).replace("\\", "/").lstrip("/")
                if ".." in rel_path.split("/"):
                    # Fallback: flatten filename with sha256 to avoid traversal
                    rel_path = f"flattened/{os.path.basename(p)}"
            except Exception:
                rel_path = f"flattened/{os.path.basename(p)}"

            root_id = hashlib.sha256(owning_root.encode("utf-8")).hexdigest()[:8]
            snap_key = f"SOURCE_SNAPSHOTS/{root_id}/{rel_path}"

            # Check binary
            try:
                with open(p, "rb") as f:
                    chunk = f.read(1024)
                    if b"\x00" in chunk:
                        continue
                fsize = os.path.getsize(p)
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    content_text = f.read(max_snap_size)

                if fsize > max_snap_size:
                    content_text += f"\n\n[TRUNCATED: File size {fsize} bytes exceeds limit {max_snap_size} bytes]"
                    missing_truncated_snapshots.append({"path": p, "reason": "truncated_size"})

                source_snapshots[snap_key] = content_text.encode("utf-8")
            except Exception as e:
                missing_truncated_snapshots.append({"path": p, "reason": str(e)})

        session_delta_payload = {
            "last_owner_request": last_owner_request,
            "last_model_response": last_model_response,
            "transcript_delta_lines": transcript_delta_lines,
            "tool_calls_delta": tool_calls_delta,
        }

        def _build_file_bytes(content, is_jsonl=False):
            if is_jsonl:
                if not content:
                    return b""
                if isinstance(content[0], dict):
                    raw = "\n".join(json.dumps(c) for c in content).encode("utf-8")
                else:
                    raw = "\n".join(content).encode("utf-8")
            else:
                raw = content.encode("utf-8") if content else b""
            
            orig_size = len(raw)
            if orig_size > 500_000:
                trunc = raw[:500_000]
                trunc_suffix = b"\n" + json.dumps({"truncated": True, "original_size_bytes": orig_size, "included_size_bytes": 500_000}).encode("utf-8")
                return trunc + trunc_suffix
            return raw

        b_owner = _build_file_bytes(last_owner_request) or b"[NO_OWNER_REQUEST_IN_CURRENT_INTERVAL]"
        b_model = _build_file_bytes(last_model_response) or b"[NO_MODEL_RESPONSE_IN_CURRENT_INTERVAL]"
        b_transcript = _build_file_bytes(transcript_delta_lines, is_jsonl=True)
        b_tools = _build_file_bytes(tool_calls_delta, is_jsonl=True)

        session_delta_files = {
            "SESSION_DELTA/LAST_OWNER_REQUEST.md": b_owner,
            "SESSION_DELTA/LAST_MODEL_RESPONSE.md": b_model,
            "SESSION_DELTA/TRANSCRIPT_DELTA.jsonl": b_transcript,
            "SESSION_DELTA/TOOL_EVENTS.jsonl": b_tools,
        }

        session_delta_non_empty = bool(
            last_owner_request or 
            last_model_response or 
            transcript_delta_lines or 
            tool_calls_delta
        )

        # If transcript/tool delta is empty but we have owner request/model response,
        # check if this is because cursor hasn't moved (no new events in interval)
        no_new_events_receipt = None
        if not transcript_delta_lines and not tool_calls_delta:
            prev_line = self.prev_processed_line or 0
            if current_line_idx <= prev_line or current_line_idx == prev_line:
                no_new_events_receipt = {
                    "no_new_events": True,
                    "cursor_before": prev_line,
                    "cursor_after": current_line_idx,
                    "reason": "cursor_unchanged_no_new_transcript_or_tool_events_in_interval",
                }
                # Include the receipt in TOOL_EVENTS.jsonl
                receipt_line = json.dumps(no_new_events_receipt).encode("utf-8")
                session_delta_files["SESSION_DELTA/TOOL_EVENTS.jsonl"] = receipt_line

        return {
            "current_line_idx": current_line_idx,
            "touched_roots": touched_roots_payload,
            "touched_files": touched_files_payload,
            "command_trace": command_trace_payload,
            "source_snapshots": source_snapshots,
            "missing_truncated_snapshots": missing_truncated_snapshots,
            "privacy_exclusions": privacy_exclusions,
            "session_delta": session_delta_payload,
            "session_delta_files": session_delta_files,
            "session_delta_non_empty": session_delta_non_empty,
            "no_new_events_receipt": no_new_events_receipt,
            "implementation_roots": implementation_roots,
            "primary_implementation_root": primary_impl_root,
            "multi_root_task": multi_root_task,
            "uncaptured_external_write_root": uncaptured_external_write_root,
        }
