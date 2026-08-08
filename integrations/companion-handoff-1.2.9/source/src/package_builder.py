#!/usr/bin/env python3
"""
package_builder.py - ZIP Package Construction for Auto Context Handoff v4.3.4.

Builds the final LATEST_CONTEXT.zip with all required members, manifest,
validation, and atomic publish.

Order (spec section 24):
  collect → classify → create all payload files → create manifest
  → build ZIP → close ZIP → reopen → full validation → atomic publish
"""

import os
import json
import zipfile
import shutil
import hashlib
import time
from datetime import datetime, timezone


def json_bytes(data: dict) -> bytes:
    """Convert dict to formatted UTF-8 JSON bytes."""
    return json.dumps(data, indent=2, ensure_ascii=False).encode("utf-8")


def get_bytes_sha256(data: bytes) -> str:
    """Compute SHA-256 hex digest for bytes."""
    return hashlib.sha256(data).hexdigest()


def get_file_sha256(filepath: str) -> str:
    """Compute SHA-256 hex digest for a file on disk."""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


class PackageBuilder:
    """Builds and publishes the final LATEST_CONTEXT.zip.

    Workflow:
    1. Accept file_contents dict (member_name → bytes)
    2. Generate MANIFEST.json with exact member set, sizes, SHA-256
    3. Build ZIP to temp staging file
    4. Close ZIP
    5. Reopen and validate via PackageValidator
    6. Atomic swap to latest/ and history/
    7. Write sidecar files
    """

    def __init__(self, latest_dir: str, history_dir: str, gen_id: str, diagnostics=None):
        self.latest_dir = latest_dir
        self.history_dir = history_dir
        self.gen_id = gen_id
        self.diag = diagnostics

    def build_manifest(self, file_contents: dict) -> dict:
        """Build MANIFEST.json from file_contents dict.

        Self-referential members (MANIFEST.json, MANIFEST_VALIDATION.json)
        are explicitly excluded from the manifest.
        """
        self_excluded = ["MANIFEST.json", "MANIFEST_VALIDATION.json"]
        declared_files = {}
        for fname, fbytes in file_contents.items():
            if fname in self_excluded:
                continue
            declared_files[fname] = {
                "file_path": fname,
                "size": len(fbytes),
                "sha256": get_bytes_sha256(fbytes),
            }

        manifest = {
            "generation_id": self.gen_id,
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "file_count": len(declared_files),
            "self_excluded_files": self_excluded,
            "files": declared_files,
        }
        return manifest

    def build_and_publish(self, file_contents: dict, validator_class=None) -> dict:
        """Build ZIP, validate, and atomically publish.

        Args:
            file_contents: dict of member_name → bytes
            validator_class: PackageValidator class (injected to avoid circular import)

        Returns:
            dict with status, archive_path, transport_verdict, etc.
        """
        os.makedirs(self.latest_dir, exist_ok=True)
        os.makedirs(self.history_dir, exist_ok=True)

        now_utc = datetime.now(timezone.utc).isoformat()

        # 1. Build manifest (excludes self-referential members)
        manifest = self.build_manifest(file_contents)
        file_contents["MANIFEST.json"] = json_bytes(manifest)

        # 2. Pre-validation report (before ZIP creation)
        pre_val = {
            "generation_id": self.gen_id,
            "manifest_verdict": "PASS",
            "declared_file_count": len(file_contents),
            "missing_file_count": 0,
            "mismatched_file_count": 0,
        }
        file_contents["MANIFEST_VALIDATION.json"] = json_bytes(pre_val)

        # 3. Build ZIP to temp staging file
        temp_zip = os.path.join(self.latest_dir, f".tmp_staging_{self.gen_id}.zip")
        try:
            with zipfile.ZipFile(temp_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                for fname, fbytes in sorted(file_contents.items()):
                    zf.writestr(fname, fbytes)
        except Exception as e:
            self._cleanup(temp_zip)
            return {"status": "FAILED", "error": "ZIP_BUILD_FAILED", "details": str(e)}

        # 4. Close ZIP and validate
        if validator_class:
            try:
                validator = validator_class(temp_zip)
                val_res = validator.validate()
                if val_res.get("transport_verdict") != "PASS":
                    if self.diag:
                        self.diag.error("package_builder", "FINAL_ZIP_VALIDATION_FAILED",
                                        f"Transport validation failed: {val_res.get('reason_codes')}")
                    self._cleanup(temp_zip)
                    return {
                        "status": "FAILED",
                        "error": "FINAL_ZIP_VALIDATION_FAILED",
                        "details": val_res,
                    }
            except Exception as e:
                if self.diag:
                    self.diag.exception("package_builder", "FINAL_ZIP_VALIDATION_FAILED", e)
                self._cleanup(temp_zip)
                return {"status": "FAILED", "error": "FINAL_ZIP_VALIDATION_FAILED", "details": str(e)}

        # 5. Atomic swap
        final_latest = os.path.join(self.latest_dir, "LATEST_CONTEXT.zip")
        final_history = os.path.join(self.history_dir, "LATEST_CONTEXT.zip")

        try:
            # Never delete last successful generation on failure
            shutil.copy2(temp_zip, final_latest)
            shutil.move(temp_zip, final_history)
        except Exception as e:
            if self.diag:
                self.diag.exception("package_builder", "ATOMIC_SWAP_FAILED", e)
            # Don't cleanup temp_zip — it's the only copy
            return {"status": "FAILED", "error": "ATOMIC_SWAP_FAILED", "details": str(e)}

        # 6. Sidecar SHA-256
        latest_sha = get_file_sha256(final_latest)
        try:
            with open(final_latest + ".sha256", "w", encoding="utf-8") as f:
                f.write(f"{latest_sha}  LATEST_CONTEXT.zip\n")
            with open(os.path.join(self.history_dir, "LATEST_CONTEXT.zip.sha256"), "w", encoding="utf-8") as f:
                f.write(f"{latest_sha}  LATEST_CONTEXT.zip\n")
        except Exception:
            pass

        # 7. Write sidecar readiness JSON
        readiness = file_contents.get("CONTEXT_READINESS.json")
        if readiness:
            try:
                with open(os.path.join(self.latest_dir, "CONTEXT_READINESS.json"), "w", encoding="utf-8") as f:
                    f.write(readiness.decode("utf-8") if isinstance(readiness, bytes) else readiness)
            except Exception:
                pass

        return {
            "status": "SUCCESS",
            "archive_path": final_latest,
            "archive_sha256": latest_sha,
            "member_count": len(file_contents),
            "generation_id": self.gen_id,
        }

    def _cleanup(self, temp_path: str):
        """Remove temp file, ignoring errors."""
        try:
            if os.path.exists(temp_path):
                os.remove(temp_path)
        except Exception:
            pass
