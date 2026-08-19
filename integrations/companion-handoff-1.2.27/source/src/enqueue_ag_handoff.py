#!/usr/bin/env python3
"""
enqueue_ag_handoff.py - Fast Queue-Only Antigravity Stop Hook Handler v4.3.5

Receives Stop payload from stdin, validates mandatory fields, performs UTF-8 decoding,
enqueues the job into queue/, and immediately launches the worker in the background.
"""

import sys
import os
import json
import time
import hashlib
import shutil
import subprocess
from datetime import datetime, timezone

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

def write_json_atomic(path, payload):
    temp_path = f"{path}.tmp.{os.getpid()}"
    with open(temp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(temp_path, path)

def resolve_base_dir() -> str:
    env_dir = os.environ.get("COMPANION_HANDOFF_DIR")
    if env_dir and os.path.isdir(env_dir):
        return os.path.abspath(env_dir)
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def trigger_worker_immediate(base_dir: str):
    try:
        worker_script = os.path.join(base_dir, "src", "run_ag_handoff_worker.py")
        if not os.path.isfile(worker_script):
            return
        python_exe = sys.executable or shutil.which("pythonw") or shutil.which("python") or "python"
        flags = 0
        if sys.platform == "win32":
            CREATE_NO_WINDOW = 0x08000000
            DETACHED_PROCESS = 0x00000008
            flags = CREATE_NO_WINDOW | DETACHED_PROCESS
        subprocess.Popen(
            [python_exe, worker_script],
            cwd=base_dir,
            creationflags=flags,
            close_fds=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
    except Exception as e:
        log_error(os.path.join(base_dir, "logs"), "WORKER_TRIGGER_FAILED", str(e))

def enqueue_stop_payload(payload, base_dir):
    """Queue one validated Stop payload, or defer it without publishing work."""
    queue_dir = os.path.join(base_dir, "queue")
    logs_dir = os.path.join(base_dir, "logs")
    os.makedirs(queue_dir, exist_ok=True)
    os.makedirs(logs_dir, exist_ok=True)

    received_at_utc = datetime.now(timezone.utc).isoformat()
    if payload.get("fullyIdle") is not True:
        log_error(logs_dir, "DEFERRED_IN_FLIGHT", "Stop payload was not fully idle; no queue item or archive was created.")
        return {"status": "DEFERRED", "reason": "stop_payload_not_fully_idle", "queue_path": None}

    conv_id = payload["conversationId"]
    exec_num = payload["executionNum"]
    t_path = payload["transcriptPath"]
    a_path = payload["artifactDirectoryPath"]
    ws_paths = payload["workspacePaths"]
    term_reason = payload["terminationReason"]
    err_msg = payload.get("error", "")

    timestamp_str = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
    fingerprint_raw = f"{conv_id}_{exec_num}"
    fingerprint = get_sha256(fingerprint_raw)
    fingerprint_prefix = fingerprint[:8]

    for f_name in os.listdir(queue_dir):
        if f_name.startswith("queue_") and f_name.endswith(".json") and fingerprint_prefix in f_name:
            log_error(logs_dir, "DUPLICATE_EVENT", f"Suppressed duplicate queue item for {conv_id} exec {exec_num}")
            return {"status": "DUPLICATE", "reason": "pending_event_exists", "queue_path": None}

    queue_item = {
        "schema_version": "4.3.4",
        "conversation_id": conv_id,
        "workspace_paths": ws_paths,
        "transcript_path": t_path,
        "artifact_directory_path": a_path,
        "execution_num": exec_num,
        "termination_reason": term_reason,
        "error": err_msg,
        "fully_idle": True,
        "received_at_utc": received_at_utc,
        "event_fingerprint": fingerprint,
        "stop_payload": payload,
    }

    target_name = f"queue_{timestamp_str}_ex{exec_num}_{conv_id[:8]}_{fingerprint_prefix}.json"
    final_path = os.path.join(queue_dir, target_name)
    write_json_atomic(final_path, queue_item)
    trigger_worker_immediate(base_dir)
    return {"status": "QUEUED", "reason": "fully_idle", "queue_path": final_path}

def main():
    base_dir = resolve_base_dir()
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
            enqueue_res = enqueue_stop_payload(payload, base_dir)
            if enqueue_res and enqueue_res.get("status") == "QUEUED":
                try:
                    pythonw_path = sys.executable
                    if pythonw_path.endswith("python.exe"):
                        candidate_w = pythonw_path[:-4] + "w.exe"
                        if os.path.exists(candidate_w):
                            pythonw_path = candidate_w
                    worker_script = os.path.join(base_dir, "src", "run_ag_handoff_worker.py")
                    DETACHED_PROCESS = 0x00000008
                    CREATE_NO_WINDOW = 0x08000000
                    import subprocess
                    subprocess.Popen(
                        [pythonw_path, worker_script],
                        creationflags=DETACHED_PROCESS | CREATE_NO_WINDOW,
                        close_fds=True
                    )
                except Exception:
                    pass
        except Exception as e:
            log_error(logs_dir, "QUEUE_WRITE_FAILED", f"Queue item write exception: {str(e)}")
            
    sys.stdout.write(json.dumps({"decision": "approve"}) + "\n")
    sys.stdout.flush()
    sys.exit(0)

if __name__ == "__main__":
    main()
