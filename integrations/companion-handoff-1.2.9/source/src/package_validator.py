#!/usr/bin/env python3
"""
package_validator.py - Package validation module for Auto Context Handoff v4.3.4.

Validates closed ZIP archives:
- CRC check
- No duplicate member paths
- No traversal paths (.. / absolute drive prefix / leading slashes)
- Exact member set comparison
- Size & SHA-256 member verification
"""

import zipfile
import hashlib
import json
import re

def get_bytes_sha256(data_bytes):
    return hashlib.sha256(data_bytes).hexdigest()

def is_unsafe_zip_path(path):
    if not path:
        return True
    p = path.replace("\\", "/")
    # Traversal check
    parts = p.split("/")
    if ".." in parts:
        return True
    # Drive prefix check (e.g. C:)
    if len(p) >= 2 and p[1] == ":":
        return True
    # Leading slash check
    if p.startswith("/"):
        return True
    return False

class PackageValidator:
    def __init__(self, zip_path):
        self.zip_path = zip_path

    def validate(self):
        crc_passed = False
        manifest_present = False
        exact_set_match = False
        all_hashes_matched = False
        no_unsafe_paths = True
        no_duplicates = True

        declared_count = 0
        actual_count = 0
        reason_codes = []

        try:
            with zipfile.ZipFile(self.zip_path, "r") as zf:
                bad_file = zf.testzip()
                crc_passed = (bad_file is None)
                if not crc_passed:
                    reason_codes.append(f"CRC_FAILED_{bad_file}")

                namelist = zf.namelist()
                actual_count = len(namelist)

                # Check duplicate member paths
                if len(namelist) != len(set(namelist)):
                    no_duplicates = False
                    reason_codes.append("DUPLICATE_ZIP_MEMBERS")

                # Check unsafe traversal paths
                for member in namelist:
                    if is_unsafe_zip_path(member):
                        no_unsafe_paths = False
                        reason_codes.append(f"UNSAFE_TRAVERSAL_PATH_{member}")

                if "MANIFEST.json" in namelist:
                    manifest_present = True
                    manifest_bytes = zf.read("MANIFEST.json")
                    manifest_data = json.loads(manifest_bytes.decode("utf-8-sig"))
                    declared_files = manifest_data.get("files", {})
                    self_excluded = set(manifest_data.get("self_excluded_files", []))
                    declared_count = len(declared_files)

                    actual_members = set(namelist)
                    expected_members = set(declared_files.keys()) | {"MANIFEST.json"} | self_excluded

                    unmatched_actual = actual_members - expected_members - self_excluded - {
                        "MANIFEST.json", "MANIFEST_VALIDATION.json", "CONTEXT_READINESS.json", "COMPANION_ENTRY.md"
                    }
                    missing_declared = expected_members - actual_members - self_excluded

                    exact_set_match = (len(unmatched_actual) == 0 and len(missing_declared) == 0)
                    if not exact_set_match:
                        if unmatched_actual:
                            reason_codes.append(f"UNDECLARED_MEMBERS_{len(unmatched_actual)}")
                        if missing_declared:
                            reason_codes.append(f"MISSING_DECLARED_MEMBERS_{len(missing_declared)}")

                    all_hashes_matched = True
                    for member, meta in declared_files.items():
                        if member not in namelist:
                            all_hashes_matched = False
                            continue
                        member_bytes = zf.read(member)
                        if len(member_bytes) != meta.get("size"):
                            all_hashes_matched = False
                            reason_codes.append(f"SIZE_MISMATCH_{member}")
                        if get_bytes_sha256(member_bytes) != meta.get("sha256"):
                            all_hashes_matched = False
                            reason_codes.append(f"HASH_MISMATCH_{member}")
                else:
                    reason_codes.append("MANIFEST_MISSING")
        except Exception as e:
            reason_codes.append(f"ZIP_READ_ERROR_{e}")

        transport_verdict = "PASS" if (
            crc_passed and manifest_present and exact_set_match and all_hashes_matched and no_unsafe_paths and no_duplicates
        ) else "FAIL"

        return {
            "transport_verdict": transport_verdict,
            "crc_passed": crc_passed,
            "manifest_present": manifest_present,
            "exact_set_match": exact_set_match,
            "all_hashes_matched": all_hashes_matched,
            "no_unsafe_paths": no_unsafe_paths,
            "no_duplicates": no_duplicates,
            "declared_count": declared_count,
            "actual_count": actual_count,
            "reason_codes": reason_codes,
        }
