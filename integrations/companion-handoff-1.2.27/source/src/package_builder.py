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

    def __init__(self, latest_dir: str, history_dir: str, gen_id: str, diagnostics=None, proj_slug: str = None):
        self.latest_dir = latest_dir
        self.history_dir = history_dir
        self.gen_id = gen_id
        self.diag = diagnostics
        self.proj_slug = proj_slug or "PROJECT"

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

    def _replace_atomically(self, source: str, target: str):
        """Bounded retry for transient Windows readers; every attempt is atomic."""
        last_error = None
        for attempt in range(20):
            try:
                os.replace(source, target)
                return
            except PermissionError as error:
                last_error = error
                if attempt == 19:
                    break
                time.sleep(0.025)
        raise last_error

    def build_and_publish(self, file_contents: dict, validator_class=None, pre_publish_guard=None) -> dict:
        """Build ZIP, validate, and atomically publish.

        Args:
            file_contents: dict of member_name → bytes
            validator_class: PackageValidator class (injected to avoid circular import)
            pre_publish_guard: callable revalidating idle/authority state immediately
                before any externally visible file is replaced

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

        # 5. Determine unique filename and stage every published file on its destination volume.
        import re
        clean_proj = re.sub(r'[^\w\-]+', '_', self.proj_slug or "PROJECT").strip('_')
        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        unique_zip_name = f"{clean_proj}_LATEST_CONTEXT_{timestamp_str}.zip"

        final_named_latest = os.path.join(self.latest_dir, unique_zip_name)
        final_named_history = os.path.join(self.history_dir, unique_zip_name)
        final_canonical_latest = os.path.join(self.latest_dir, "LATEST_CONTEXT.zip")
        final_canonical_history = os.path.join(self.history_dir, "LATEST_CONTEXT.zip")

        final_named_sha = final_named_latest + ".sha256"
        final_canonical_sha = final_canonical_latest + ".sha256"
        final_history_sha = final_canonical_history + ".sha256"
        final_readiness = os.path.join(self.latest_dir, "CONTEXT_READINESS.json")
        latest_sha = get_file_sha256(temp_zip)

        named_stage = os.path.join(self.latest_dir, f".tmp_named_{self.gen_id}.zip")
        history_stage = os.path.join(self.history_dir, f".tmp_history_{self.gen_id}.zip")
        history_named_stage = os.path.join(self.history_dir, f".tmp_history_named_{self.gen_id}.zip")
        latest_sha_stage = os.path.join(self.latest_dir, f".tmp_latest_sha_{self.gen_id}")
        named_sha_stage = os.path.join(self.latest_dir, f".tmp_named_sha_{self.gen_id}")
        history_sha_stage = os.path.join(self.history_dir, f".tmp_history_sha_{self.gen_id}")
        readiness_stage = os.path.join(self.latest_dir, f".tmp_readiness_{self.gen_id}")

        staged_paths = [
            temp_zip,
            named_stage,
            history_stage,
            history_named_stage,
            latest_sha_stage,
            named_sha_stage,
            history_sha_stage,
        ]
        replacements = []
        try:
            shutil.copy2(temp_zip, named_stage)
            shutil.copy2(temp_zip, history_stage)
            shutil.copy2(temp_zip, history_named_stage)

            sha_canonical_bytes = f"{latest_sha}  LATEST_CONTEXT.zip\n".encode("utf-8")
            sha_named_bytes = f"{latest_sha}  {unique_zip_name}\n".encode("utf-8")

            with open(latest_sha_stage, "wb") as handle:
                handle.write(sha_canonical_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            with open(named_sha_stage, "wb") as handle:
                handle.write(sha_named_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            with open(history_sha_stage, "wb") as handle:
                handle.write(sha_canonical_bytes)
                handle.flush()
                os.fsync(handle.fileno())

            # Clean previous uniquely named zip files older than 5 minutes from latest_dir to prevent old files buildup
            try:
                now_epoch = time.time()
                for old_f in os.listdir(self.latest_dir):
                    old_path = os.path.join(self.latest_dir, old_f)
                    if old_f.endswith(".zip") and old_f != "LATEST_CONTEXT.zip" and not old_f.startswith(".tmp") and not old_f.startswith(".rollback"):
                        try:
                            if now_epoch - os.path.getmtime(old_path) > 300:
                                os.remove(old_path)
                        except Exception:
                            pass
                    if old_f.endswith(".zip.sha256") and old_f != "LATEST_CONTEXT.zip.sha256" and not old_f.startswith(".tmp") and not old_f.startswith(".rollback"):
                        try:
                            if now_epoch - os.path.getmtime(old_path) > 300:
                                os.remove(old_path)
                        except Exception:
                            pass
            except Exception:
                pass

            replacements = [
                (temp_zip, final_canonical_latest),
                (named_stage, final_named_latest),
                (history_stage, final_canonical_history),
                (history_named_stage, final_named_history),
                (latest_sha_stage, final_canonical_sha),
                (named_sha_stage, final_named_sha),
                (history_sha_stage, final_history_sha),
            ]
            readiness = file_contents.get("CONTEXT_READINESS.json")
            if readiness is not None:
                readiness_bytes = readiness if isinstance(readiness, bytes) else str(readiness).encode("utf-8")
                with open(readiness_stage, "wb") as handle:
                    handle.write(readiness_bytes)
                    handle.flush()
                    os.fsync(handle.fileno())
                staged_paths.append(readiness_stage)
                replacements.append((readiness_stage, final_readiness))
        except Exception as e:
            for path in staged_paths:
                self._cleanup(path)
            if self.diag:
                self.diag.exception("package_builder", "PUBLISH_STAGING_FAILED", e)
            return {"status": "FAILED", "error": "PUBLISH_STAGING_FAILED", "details": str(e)}

        # 6. Prepare rollback copies before the last authority check. A large
        # previous archive must not widen the check-to-swap race window.
        backups = {}
        try:
            for _, target in replacements:
                if os.path.exists(target):
                    backup = os.path.join(
                        os.path.dirname(target),
                        f".rollback_{self.gen_id}_{os.path.basename(target)}",
                    )
                    shutil.copy2(target, backup)
                    backups[target] = backup
                else:
                    backups[target] = None
        except Exception as e:
            for path in staged_paths:
                self._cleanup(path)
            for backup in backups.values():
                if backup:
                    self._cleanup(backup)
            return {"status": "FAILED", "error": "ROLLBACK_STAGING_FAILED", "details": str(e)}

        # 7. Recheck the exact authority/quiescence snapshot after build,
        # validation and rollback staging, immediately before the first swap.
        guard_result = None
        if pre_publish_guard:
            try:
                guard_result = pre_publish_guard()
            except Exception as e:
                guard_result = {"ready": False, "reason": f"guard_exception:{type(e).__name__}"}
            if not isinstance(guard_result, dict) or not guard_result.get("ready"):
                for path in staged_paths:
                    self._cleanup(path)
                for backup in backups.values():
                    if backup:
                        self._cleanup(backup)
                return {
                    "status": "DEFERRED",
                    "error": "PRE_PUBLISH_GUARD_FAILED",
                    "details": guard_result,
                }
            # os.replace preserves the staged file timestamp. Advance both ZIP
            # stages only after the guard so final mtime is a publication-time
            # boundary, never an earlier build-time timestamp.
            try:
                publication_mtime_ns = time.time_ns()
                checked_at_utc = guard_result.get("checked_at_utc")
                if checked_at_utc:
                    checked_at = datetime.fromisoformat(checked_at_utc.replace("Z", "+00:00"))
                    checked_ns = int(checked_at.timestamp() * 1_000_000_000)
                    publication_mtime_ns = max(publication_mtime_ns, checked_ns + 1_000_000)
                os.utime(temp_zip, ns=(publication_mtime_ns, publication_mtime_ns))
                os.utime(named_stage, ns=(publication_mtime_ns, publication_mtime_ns))
                os.utime(history_stage, ns=(publication_mtime_ns, publication_mtime_ns))
                os.utime(history_named_stage, ns=(publication_mtime_ns, publication_mtime_ns))
            except Exception as e:
                for path in staged_paths:
                    self._cleanup(path)
                for backup in backups.values():
                    if backup:
                        self._cleanup(backup)
                return {"status": "FAILED", "error": "PUBLISH_TIMESTAMP_FAILED", "details": str(e)}

        # 8. Each visible file is replaced atomically. The transaction keeps
        # metadata-preserving backups and restores the complete prior set if a
        # later replacement fails.
        published_targets = []
        try:
            for stage, target in replacements:
                self._replace_atomically(stage, target)
                published_targets.append(target)
            if get_file_sha256(final_canonical_latest) != latest_sha or get_file_sha256(final_named_latest) != latest_sha:
                raise RuntimeError("post_publish_archive_hash_mismatch")
            with open(final_canonical_sha, "rb") as handle:
                if handle.read() != sha_canonical_bytes:
                    raise RuntimeError("post_publish_canonical_sidecar_mismatch")
            with open(final_named_sha, "rb") as handle:
                if handle.read() != sha_named_bytes:
                    raise RuntimeError("post_publish_named_sidecar_mismatch")
            with open(final_history_sha, "rb") as handle:
                if handle.read() != sha_canonical_bytes:
                    raise RuntimeError("post_publish_history_sidecar_mismatch")
            if readiness is not None:
                with open(final_readiness, "rb") as handle:
                    if handle.read() != readiness_bytes:
                        raise RuntimeError("post_publish_readiness_mismatch")
        except Exception as e:
            rollback_errors = []
            retained_backups = set()
            for target in reversed(published_targets):
                backup = backups.get(target)
                try:
                    if backup and os.path.exists(backup):
                        self._replace_atomically(backup, target)
                    elif os.path.exists(target):
                        os.remove(target)
                except Exception as rollback_error:
                    rollback_errors.append(f"{os.path.basename(target)}:{type(rollback_error).__name__}")
                    if backup and os.path.exists(backup):
                        retained_backups.add(backup)
            for path in staged_paths:
                self._cleanup(path)
            for backup in backups.values():
                if backup and backup not in retained_backups:
                    self._cleanup(backup)
            if self.diag:
                self.diag.exception("package_builder", "ATOMIC_SWAP_FAILED", e)
            return {
                "status": "FAILED",
                "error": "ATOMIC_ROLLBACK_FAILED" if rollback_errors else "ATOMIC_SWAP_FAILED",
                "details": {"publish_error": str(e), "rollback_errors": rollback_errors},
            }

        for backup in backups.values():
            if backup:
                self._cleanup(backup)

        final_mtime_ns = os.stat(final_canonical_latest).st_mtime_ns
        now_ns = time.time_ns()
        if now_ns < final_mtime_ns:
            time.sleep((final_mtime_ns - now_ns) / 1_000_000_000)
        published_at_utc = datetime.now(timezone.utc).isoformat()

        return {
            "status": "SUCCESS",
            "archive_path": final_named_latest,
            "canonical_archive_path": final_canonical_latest,
            "archive_name": unique_zip_name,
            "archive_sha256": latest_sha,
            "member_count": len(file_contents),
            "generation_id": self.gen_id,
            "published_at_utc": published_at_utc,
            "atomic_latest_publish": True,
            "quiescence_checked_at_utc": guard_result.get("checked_at_utc") if guard_result else None,
        }

    def _cleanup(self, temp_path: str):
        """Remove temp file, ignoring errors."""
        try:
            if os.path.exists(temp_path):
                os.remove(temp_path)
        except Exception:
            pass
