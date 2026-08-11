#!/usr/bin/env python3
"""
run_ag_ux_helper.py - Antigravity Companion Handoff Clean UX Helper v4.3.4

Atomic Win32 clipboard delivery of ONLY the pure absolute ZIP path.
Zero prompt text appended, zero explorer windows, zero System.Windows.Forms calls.
"""

import sys
import os
import json
import time
import shutil
import ctypes
import subprocess

def win32_set_single_clipboard(text_to_set, max_attempts=5):
    CF_UNICODETEXT = 13
    GMEM_MOVEABLE = 0x0002
    
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    
    user32.SetClipboardData.restype = ctypes.c_void_p
    user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    
    user32.GetClipboardData.restype = ctypes.c_void_p
    user32.GetClipboardData.argtypes = [ctypes.c_uint]
    
    attempts = 0
    roundtrip_match = False
    
    for attempt in range(1, max_attempts + 1):
        attempts = attempt
        try:
            if user32.OpenClipboard(None):
                user32.EmptyClipboard()
                encoded = text_to_set.encode('utf-16-le') + b'\x00\x00'
                h_mem = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(encoded))
                if h_mem:
                    ptr = kernel32.GlobalLock(h_mem)
                    if ptr:
                        ctypes.memmove(ptr, encoded, len(encoded))
                        kernel32.GlobalUnlock(h_mem)
                        user32.SetClipboardData(CF_UNICODETEXT, h_mem)
                user32.CloseClipboard()
                
                time.sleep(0.05)
                if user32.OpenClipboard(None):
                    h_read = user32.GetClipboardData(CF_UNICODETEXT)
                    if h_read:
                        ptr_read = kernel32.GlobalLock(h_read)
                        if ptr_read:
                            read_text = ctypes.wstring_at(ptr_read)
                            kernel32.GlobalUnlock(h_read)
                            if read_text == text_to_set:
                                roundtrip_match = True
                    user32.CloseClipboard()
                    
                if roundtrip_match:
                    break
        except Exception:
            pass
        time.sleep(0.1)
        
    return attempts, 0 if roundtrip_match else -1, roundtrip_match

def process_ux_request(req_path, override_base_dir=None):
    if not os.path.exists(req_path):
        return None
        
    try:
        with open(req_path, "r", encoding="utf-8") as f:
            req_data = json.load(f)
    except Exception as e:
        print(f"[UX Helper Error] Failed to read request {req_path}: {e}")
        return None
        
    gen_id = req_data.get("generation_id", "unknown_gen")
    zip_path = req_data.get("zip_path", "")
    cfg_opts = req_data.get("config_options", {})
    clip_pref = cfg_opts.get("clipboard_content", "zip_path")
    open_explorer = cfg_opts.get("open_explorer_after_publish", False)

    if clip_pref == "companion_message":
        text_to_set = "Проанализируй приложенный LATEST_CONTEXT.zip по COMPANION_ENTRY.md."
    else:
        text_to_set = zip_path
        
    # Atomic 64-bit Win32 clipboard write
    write_attempts, clip_exit_code, roundtrip_match = win32_set_single_clipboard(text_to_set, max_attempts=5)
    
    explorer_open_success = False
    if open_explorer and zip_path and os.path.exists(zip_path):
        try:
            subprocess.Popen(['explorer.exe', f'/select,{zip_path}'])
            explorer_open_success = True
        except Exception:
            pass
            
    notification_success = False
    try:
        MB_ICONASTERISK = 0x00000040
        ctypes.windll.user32.MessageBeep(MB_ICONASTERISK)
        notification_success = True
    except Exception:
        pass
    
    ux_verdict = "PASS" if roundtrip_match else "CLIPBOARD_FAILED"
        
    result_data = {
        "generation_id": gen_id,
        "clipboard_write_attempts": write_attempts,
        "clipboard_command_exit_code": clip_exit_code,
        "clipboard_roundtrip_match": roundtrip_match,
        "explorer_open_success": explorer_open_success,
        "browser_open_success": False,
        "notification_success": notification_success,
        "verdict": ux_verdict,
        "processed_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    }
    
    res_dir = os.path.dirname(req_path)
    res_file = os.path.join(res_dir, f"UX_RESULT_{gen_id}.json")
    tmp_res = os.path.join(res_dir, f".tmp_UX_RESULT_{gen_id}.json")
    
    with open(tmp_res, "w", encoding="utf-8") as f:
        json.dump(result_data, f, ensure_ascii=False, indent=2)
    os.replace(tmp_res, res_file)
    
    latest_ux_result = req_data.get("latest_ux_result_path")
    if latest_ux_result:
        os.makedirs(os.path.dirname(latest_ux_result), exist_ok=True)
        shutil.copy2(res_file, os.path.join(os.path.dirname(latest_ux_result), ".tmp_UX_RESULT.json"))
        os.replace(os.path.join(os.path.dirname(latest_ux_result), ".tmp_UX_RESULT.json"), latest_ux_result)
        
    return result_data

def main():
    base_dir = r"C:\Scripts\AntigravityProjects\companion-handoff"
    req_dir = os.path.join(base_dir, "queue", "ux_requests")
    if not os.path.exists(req_dir):
        os.makedirs(req_dir, exist_ok=True)
        
    req_files = [f for f in os.listdir(req_dir) if f.startswith("UX_REQUEST_") and f.endswith(".json")]
    for rf in req_files:
        req_p = os.path.join(req_dir, rf)
        print(f"[UX Helper] Processing request: {rf}")
        res = process_ux_request(req_p)
        if res:
            print(f"[UX Helper] Result: {res['verdict']} (Clipboard Roundtrip: {res['clipboard_roundtrip_match']})")
            try:
                os.remove(req_p)
            except Exception:
                pass
    return 0

if __name__ == "__main__":
    sys.exit(main())
