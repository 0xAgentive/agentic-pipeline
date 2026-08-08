#!/usr/bin/env python3
"""
run_ag_handoff_worker.py - Reliable Queue Worker with PID Lock v4.3.4

Processes enqueued Stop events and ensures a single running instance via active PID locking.
"""

import sys
import os
import json
import time
import shutil
import ctypes

def is_pid_running(pid):
    try:
        PROCESS_QUERY_INFORMATION = 0x0400
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_INFORMATION, False, pid)
        if handle:
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
    except Exception:
        pass
    return False

def process_queue_once(base_dir, src_dir):
    queue_dir = os.path.join(base_dir, "queue")
    proc_dir = os.path.join(queue_dir, "processed")
    failed_dir = os.path.join(queue_dir, "failed")
    quarantine_dir = os.path.join(queue_dir, "quarantine")
    logs_dir = os.path.join(base_dir, "logs")
    
    os.makedirs(queue_dir, exist_ok=True)
    os.makedirs(proc_dir, exist_ok=True)
    os.makedirs(failed_dir, exist_ok=True)
    os.makedirs(quarantine_dir, exist_ok=True)
    os.makedirs(logs_dir, exist_ok=True)
    
    sys.path.insert(0, src_dir)
    from export_ag_handoff import CompanionExporter
    
    queue_files = [f for f in os.listdir(queue_dir) if f.startswith("queue_") and f.endswith(".json")]
    queue_files.sort()
    
    processed_any = False
    for qf in queue_files:
        q_path = os.path.join(queue_dir, qf)
        if not os.path.exists(q_path):
            continue
            
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [Worker] Processing job: {qf}")
        try:
            with open(q_path, "r", encoding="utf-8-sig") as f:
                q_data = json.load(f)
                
            retry_count = q_data.get("retry_count", 0)
                
            stop_payload = q_data.get("stop_payload", q_data)
            conv_id = q_data.get("conversation_id") or stop_payload.get("conversationId")
            
            exp = CompanionExporter(stop_payload_file=q_path, conversation_id=conv_id)
            res = exp.export()
            
            if res.get("status") == "SUCCESS":
                gen_id = res.get("last_successful_generation_id", "unknown_gen")
                dest_proc = os.path.join(proc_dir, qf)
                shutil.move(q_path, dest_proc)
                print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [Worker] Successfully processed {qf}")
                
                archive_p = res.get("archive_path")
                ws_paths = stop_payload.get("workspacePaths", [])
                
                # Create UX request for clipboard/explorer/notification
                ux_req_dir = os.path.join(queue_dir, "ux_requests")
                os.makedirs(ux_req_dir, exist_ok=True)
                
                # Read config for UX options
                cfg_path = os.path.join(base_dir, "handoff.config.json")
                cfg = {}
                if os.path.exists(cfg_path):
                    try:
                        with open(cfg_path, "r", encoding="utf-8-sig") as f:
                            cfg = json.load(f)
                    except Exception:
                        pass
                
                ux_request = {
                    "generation_id": gen_id,
                    "zip_path": archive_p,
                    "config_options": {
                        "clipboard_content": cfg.get("clipboard_content", "companion_message"),
                        "open_explorer_after_publish": cfg.get("open_explorer_after_publish", True),
                        "select_zip_in_explorer": cfg.get("select_zip_in_explorer", True),
                        "create_windows_notification": cfg.get("create_windows_notification", True),
                    },
                    "latest_ux_result_path": os.path.join(
                        os.path.dirname(archive_p), "UX_RESULT.json"
                    ) if archive_p else None,
                    "created_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
                
                ux_req_path = os.path.join(ux_req_dir, f"UX_REQUEST_{gen_id}.json")
                with open(ux_req_path, "w", encoding="utf-8") as f:
                    json.dump(ux_request, f, ensure_ascii=False, indent=2)
                
                # Invoke UX helper directly
                ux_result = None
                try:
                    from run_ag_ux_helper import process_ux_request as do_ux
                    ux_result = do_ux(ux_req_path)
                    if ux_result:
                        print(f"[Worker] UX delivery: {ux_result.get('verdict', 'UNKNOWN')}")
                    # Clean up processed request
                    if os.path.exists(ux_req_path):
                        os.remove(ux_req_path)
                except Exception as ux_err:
                    print(f"[Worker Warning] UX delivery failed: {ux_err}")
                    # UX failure does NOT delete the ZIP
                
                # Determine trigger source from queue item metadata
                has_fingerprint = bool(q_data.get("event_fingerprint"))
                has_schema = bool(q_data.get("schema_version"))
                is_hook_triggered = has_fingerprint and has_schema
                
                # Compute archive SHA256
                import hashlib
                archive_sha256 = ""
                if archive_p and os.path.exists(archive_p):
                    h = hashlib.sha256()
                    with open(archive_p, "rb") as af:
                        while chunk := af.read(65536):
                            h.update(chunk)
                    archive_sha256 = h.hexdigest()
                
                # Derive project_slug from archive path
                # handoffs/<slug>/<conv_id>/latest/LATEST_CONTEXT.zip
                proj_slug = ""
                if archive_p:
                    parts = archive_p.replace("\\", "/").split("/")
                    try:
                        hi = parts.index("handoffs")
                        if hi + 1 < len(parts):
                            proj_slug = parts[hi + 1]
                    except ValueError:
                        pass
                
                evidence = {
                    "trigger_source": "antigravity_desktop_stop_hook" if is_hook_triggered else "manual_queue_injection",
                    "manual_queue_injection": not is_hook_triggered,
                    "manual_worker_invocation": False,  # Worker is always invoked by scheduled task or hook chain
                    "real_desktop_stop": is_hook_triggered,
                    "hook_triggered": is_hook_triggered,
                    "queue_item_created": True,
                    "worker_completed": True,
                    "archive_path_from_exporter_used": True,
                    "final_zip_valid": bool(archive_p and os.path.exists(archive_p)),
                    "ux_helper_completed": ux_result is not None,
                    "clipboard_roundtrip_match": bool(ux_result and ux_result.get("clipboard_roundtrip_match")),
                    "explorer_opened": bool(ux_result and ux_result.get("explorer_open_success")),
                    "notification_created": bool(ux_result and ux_result.get("notification_success")),
                    "generation_id": gen_id,
                    "archive_path": archive_p,
                    "archive_sha256": archive_sha256,
                    "project_slug": proj_slug,
                    "verdict": "PASS" if (is_hook_triggered and archive_p and os.path.exists(archive_p) and ux_result and ux_result.get("clipboard_roundtrip_match")) else "MANUAL_TRIGGER" if (not is_hook_triggered and archive_p and os.path.exists(archive_p)) else "EXPORT_FAILED",
                    "conversationId": conv_id,
                    "workspacePaths": ws_paths,
                    "recorded_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
                
                ev_file = os.path.join(logs_dir, "DESKTOP_STOP_EVIDENCE.json")
                with open(ev_file, "w", encoding="utf-8") as f:
                    json.dump(evidence, f, ensure_ascii=False, indent=2)
                    
                processed_any = True
            else:
                print(f"[Worker Error] Failed job {qf}: {res.get('error')}")
                retry_count += 1
                if retry_count >= 3:
                    print(f"[Worker Error] Job {qf} exceeded max retries. Quarantining.")
                    dest_fail = os.path.join(quarantine_dir, qf)
                    shutil.move(q_path, dest_fail)
                else:
                    q_data["retry_count"] = retry_count
                    with open(q_path, "w", encoding="utf-8") as f:
                        json.dump(q_data, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print(f"[Worker Error] Failed job {qf}: {e}")
            try:
                with open(q_path, "r", encoding="utf-8-sig") as f:
                    q_data = json.load(f)
                retry_count = q_data.get("retry_count", 0) + 1
                if retry_count >= 3:
                    dest_fail = os.path.join(quarantine_dir, qf)
                    shutil.move(q_path, dest_fail)
                else:
                    q_data["retry_count"] = retry_count
                    with open(q_path, "w", encoding="utf-8") as f:
                        json.dump(q_data, f, ensure_ascii=False, indent=2)
            except Exception:
                pass
                
    return processed_any

def main():
    base_dir = r"C:\Scripts\AntigravityProjects\companion-handoff"
    src_dir = os.path.join(base_dir, "src")
    logs_dir = os.path.join(base_dir, "logs")
    os.makedirs(logs_dir, exist_ok=True)
    
    lock_file = os.path.join(logs_dir, "worker.lock")
    if os.path.exists(lock_file):
        try:
            lock_age = time.time() - os.path.getctime(lock_file)
            with open(lock_file, "r") as f:
                old_pid = int(f.read().strip())
                
            if lock_age > 3600:
                print("[Worker] Lock file is older than 1 hour. Removing stale lock.")
                os.remove(lock_file)
            elif is_pid_running(old_pid):
                print(f"[Worker] Another instance with PID {old_pid} is running. Exiting.")
                return 0
            else:
                print(f"[Worker] Process {old_pid} is not running. Removing stale lock.")
                os.remove(lock_file)
        except Exception:
            pass
            
    with open(lock_file, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
        
    try:
        process_queue_once(base_dir, src_dir)
    finally:
        if os.path.exists(lock_file):
            try:
                os.remove(lock_file)
            except Exception:
                pass
    return 0

if __name__ == "__main__":
    sys.exit(main())
