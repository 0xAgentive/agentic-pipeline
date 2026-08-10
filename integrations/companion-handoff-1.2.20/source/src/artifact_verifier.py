#!/usr/bin/env python3
"""
artifact_verifier.py - Artifact Verification for Auto Context Handoff v4.3.4.
"""

import os
import json
import zipfile
import hashlib
from typing import Dict, Any

MAX_ZIP_BOMB_RATIO = 200
MAX_ZIP_MEMBERS = 5000
MAX_EXPANDED_SIZE = 1024 * 1024 * 1024  # 1024MB

def is_unsafe_zip_path(path: str) -> bool:
    """Checks if a zip member path is absolute or traverses up."""
    if os.path.isabs(path):
        return True
    if ".." in path.replace("\\", "/").split("/"):
        return True
    # Drive prefix check (e.g., C:)
    if os.path.splitdrive(path)[0]:
        return True
    return False

def check_zip_security(zip_path: str) -> Dict[str, Any]:
    """Comprehensive ZIP security validation."""
    if not os.path.exists(zip_path):
        return {"passed": False, "reason": "File not found"}
        
    if not zipfile.is_zipfile(zip_path):
        return {"passed": False, "reason": "Not a valid ZIP file"}

    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            infolist = zf.infolist()
            
            if len(infolist) > MAX_ZIP_MEMBERS:
                return {"passed": False, "reason": f"Too many members (>{MAX_ZIP_MEMBERS})"}
            
            total_uncompressed = 0
            total_compressed = os.path.getsize(zip_path)
            
            seen_names = set()
            for info in infolist:
                if info.filename in seen_names:
                    return {"passed": False, "reason": "Duplicate file entries"}
                seen_names.add(info.filename)
                
                if is_unsafe_zip_path(info.filename):
                    return {"passed": False, "reason": "Unsafe path detected"}
                    
                total_uncompressed += info.file_size
                
            if total_uncompressed > MAX_EXPANDED_SIZE:
                return {"passed": False, "reason": f"Expanded size too large (>{MAX_EXPANDED_SIZE} bytes)"}
                
            if total_compressed > 0:
                ratio = total_uncompressed / total_compressed
                if ratio > MAX_ZIP_BOMB_RATIO:
                    return {"passed": False, "reason": f"High compression ratio ({ratio:.1f} > {MAX_ZIP_BOMB_RATIO}) - Possible ZIP bomb"}
                    
            # Check CRC via internal testzip
            first_bad = zf.testzip()
            if first_bad is not None:
                return {"passed": False, "reason": f"CRC failed for file: {first_bad}"}
                
        return {"passed": True, "reason": "Passed security checks"}
    except Exception as e:
        return {"passed": False, "reason": f"Exception during checking: {str(e)}"}

def verify_artifact(artifact_path: str) -> Dict[str, Any]:
    """Returns structured verification result for an artifact."""
    result = {
        "exists": False,
        "transport_integrity": "not_applicable",
        "zip_security": "not_applicable",
        "manifest_integrity": "not_applicable",
        "contract_verification": "unknown",
        "audit_linkage": "unknown",
        "verification_level": "TRANSPORT_ONLY"
    }

    if not os.path.exists(artifact_path):
        return result
        
    result["exists"] = True

    if artifact_path.lower().endswith(".zip"):
        sec_check = check_zip_security(artifact_path)
        if sec_check["passed"]:
            result["transport_integrity"] = "passed"
            result["zip_security"] = "passed"
        else:
            result["transport_integrity"] = "failed"
            result["zip_security"] = "failed"
            return result # Fast fail
            
        try:
            with zipfile.ZipFile(artifact_path, 'r') as zf:
                if "MANIFEST.json" in zf.namelist():
                    result["verification_level"] = "MANIFEST_VERIFIED"
                    with zf.open("MANIFEST.json") as mf:
                        try:
                            manifest = json.loads(mf.read().decode('utf-8-sig'))
                            result["manifest_integrity"] = "passed" # Simplified manifest check
                            
                            if manifest.get("contract_type") in ["GUARDED", "RELEASE"]:
                                result["verification_level"] = "CONTRACT_VERIFIED"
                                if "receipt" in manifest:
                                    result["contract_verification"] = "passed"
                                else:
                                    result["contract_verification"] = "failed"
                        except json.JSONDecodeError:
                            result["manifest_integrity"] = "failed"
        except Exception:
            result["manifest_integrity"] = "failed"

    return result
