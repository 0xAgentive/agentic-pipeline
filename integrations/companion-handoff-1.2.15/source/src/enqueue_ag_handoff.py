#!/usr/bin/env python3
"""
enqueue_ag_handoff.py - Fast Queue-Only Antigravity Stop Hook Handler v4.3.4

Receives Stop payload from stdin, validates mandatory fields, performs UTF-8 decoding,
and enqueues the job into queue/ without running the exporter synchronously.
"""

import sys
import os
import json
import time
import hashlib

def get_sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()

def contains_mojibake(text):
    if not isinstance(text, str):
        return False
    markers = ["Р ", "РµР", "Р—Рµ", "\ufffd", "Ã", "Â"]
    for m in markers:
        if m in text:
            return True
    return False

def log_error(logs_dir, error_code, message):
    try:
        err_log = os.path.join(logs_dir, "enqueue_error.log")
        with open(err_log, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {error_code}: {message}\n")
    except Exception:
        pass

def main():
    base_dir = r"C:\Scripts\AntigravityProjects\companion-handoff"
    queue_dir = os.path.join(base_dir, "queue")
    logs_dir = os.path.join(base_dir, "logs")
    
    os.makedirs(queue_dir, exist_ok=True)
    os.makedirs(logs_dir, exist_ok=True)
    
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        
    required_keys = [
        "conversationId",
        "workspacePaths",
        "transcriptPath",
        "artifactDirectoryPath",
        "executionNum",
        "terminationReason",
        "fullyIdle"
    ]
    
    valid_payload = False
    payload = {}
    missing_fields = []
    
    try:
        raw_bytes = sys.stdin.buffer.read()
        if raw_bytes.strip():
            try:
                raw_text = raw_bytes.decode("utf-8-sig", errors="strict")
            except UnicodeDecodeError:
                raw_text = raw_bytes.decode("utf-8", errors="replace")
                
            if contains_mojibake(raw_text):
                log_error(logs_dir, "INPUT_CONTEXT_INVALID", "Mojibake detected in stdin raw input.")
            else:
                payload = json.loads(raw_text)
                
                for k in required_keys:
                    if k not in payload or payload[k] is None:
                        missing_fields.append(k)
                    elif k in ["conversationId", "transcriptPath", "artifactDirectoryPath", "terminationReason"] and not str(payload[k]).strip():
                        missing_fields.append(k)
                    elif k == "workspacePaths" and (not isinstance(payload[k], list) or len(payload[k]) == 0):
                        missing_fields.append(k)
                        
                if not missing_fields:
                    valid_payload = True
                else:
                    log_error(logs_dir, "INPUT_INVALID", f"Missing or empty required fields: {missing_fields}")
        else:
            log_error(logs_dir, "INPUT_INVALID", "Empty stdin payload received.")
            
    except Exception as e:
        log_error(logs_dir, "INPUT_INVALID", f"JSON parse error: {str(e)}")
        
    if valid_payload:
        try:
            conv_id = payload["conversationId"]
            exec_num = payload["executionNum"]
            t_path = payload["transcriptPath"]
            a_path = payload["artifactDirectoryPath"]
            ws_paths = payload["workspacePaths"]
            term_reason = payload["terminationReason"]
            err_msg = payload.get("error", "")
            fully_idle = payload["fullyIdle"]
            
            t_size = os.path.getsize(t_path) if os.path.exists(t_path) else 0
            line_count = 0
            if os.path.exists(t_path):
                try:
                    with open(t_path, "r", encoding="utf-8", errors="ignore") as f:
                        line_count = sum(1 for l in f if l.strip())
                except Exception:
                    pass
            
            timestamp_str = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
            
            # Stable event fingerprint based on conversationId + executionNum
            fingerprint_raw = f"{conv_id}_{exec_num}"
            fingerprint = get_sha256(fingerprint_raw)
            
            # Duplicate Stop suppression
            is_duplicate = False
            for f_name in os.listdir(queue_dir):
                if f_name.startswith("queue_") and fingerprint in f_name:
                    is_duplicate = True
                    break
            
            if not is_duplicate:
                queue_item = {
                    "schema_version": "4.3.4",
                    "conversation_id": conv_id,
                    "workspace_paths": ws_paths,
                    "transcript_path": t_path,
                    "artifact_directory_path": a_path,
                    "execution_num": exec_num,
                    "termination_reason": term_reason,
                    "error": err_msg,
                    "fully_idle": fully_idle,
                    "received_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "event_fingerprint": fingerprint,
                    "stop_payload": payload
                }
                
                # Include fingerprint in filename for O(1) duplicate check
                target_name = f"queue_{timestamp_str}_ex{exec_num}_{conv_id[:8]}_{fingerprint[:8]}.json"
                temp_path = os.path.join(queue_dir, f".tmp_{target_name}")
                final_path = os.path.join(queue_dir, target_name)
                
                with open(temp_path, "w", encoding="utf-8") as f:
                    json.dump(queue_item, f, ensure_ascii=False, indent=2)
                    
                os.replace(temp_path, final_path)
            else:
                log_error(logs_dir, "DUPLICATE_EVENT", f"Suppressed duplicate queue item for {conv_id} exec {exec_num}")
                
        except Exception as e:
            log_error(logs_dir, "QUEUE_WRITE_FAILED", f"Queue item write exception: {str(e)}")
            
    sys.stdout.write(json.dumps({"decision": "approve"}) + "\n")
    sys.stdout.flush()
    sys.exit(0)

if __name__ == "__main__":
    main()
