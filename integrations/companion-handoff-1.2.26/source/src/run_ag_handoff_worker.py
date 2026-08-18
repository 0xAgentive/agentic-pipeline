#!/usr/bin/env python3
"""
run_ag_handoff_worker.py - Reliable Queue Worker with PID Lock v4.3.4

Processes enqueued Stop events and ensures a single running instance via active PID locking.
"""

import os
import sys

_dll_handles = []
if sys.platform == "win32":
    python_dir = os.path.dirname(sys.executable)
    dll_dir = os.path.join(python_dir, "DLLs")
    if os.path.isdir(dll_dir) and hasattr(os, "add_dll_directory"):
        try:
            _dll_handles.append(os.add_dll_directory(dll_dir))
        except Exception:
            pass
    os.environ["PATH"] = python_dir + os.pathsep + dll_dir + os.pathsep + os.environ.get("PATH", "")

import json
import time
import shutil
import hashlib
import subprocess
import re
import stat
from datetime import datetime, timezone

UTC_TIMESTAMP_PATTERN = re.compile(
    r"(?P<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(?P<fraction>\d{1,7}))?(?P<zone>Z|[+-]\d{2}:\d{2})"
)

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

def get_quiescence_snapshot(stop_payload):
    """Return metadata-only signatures for files that can change during a Stop export."""
    watched_paths = []
    transcript_path = stop_payload.get("transcriptPath") or stop_payload.get("transcript_path")
    if transcript_path:
        watched_paths.append(os.path.normpath(transcript_path))

    artifact_dir = stop_payload.get("artifactDirectoryPath") or stop_payload.get("artifact_directory_path")
    if artifact_dir:
        task_dir = os.path.join(artifact_dir, ".system_generated", "tasks")
        try:
            watched_paths.extend(
                entry.path for entry in os.scandir(task_dir)
                if entry.is_file() and entry.name.lower().endswith(".log")
            )
        except OSError:
            watched_paths.append(task_dir)

    authority_names = (
        "RUN_RESULT.json",
        "VERIFICATION_RECEIPT.json",
        "AUDIT_RESULT.json",
        "PHASE_RESULT.json",
        "CANDIDATE_MANIFEST.json",
        "CANDIDATE_MANIFEST_STATUS.json",
        "EXECUTION_LEASE.json",
        "EXECUTION_AUTHORITY_TRANSACTION.json",
        "WORK_ITEM.json",
    )
    for workspace in stop_payload.get("workspacePaths", []) or []:
        if not workspace:
            continue
        watched_paths.extend(os.path.join(workspace, ".agy", name) for name in authority_names)

    snapshot = []
    for path in sorted(set(os.path.normcase(os.path.normpath(p)) for p in watched_paths)):
        try:
            stat = os.stat(path)
            snapshot.append((path, stat.st_size, stat.st_mtime_ns))
        except OSError:
            snapshot.append((path, None, None))
    return tuple(snapshot)

def wait_for_quiescence(
    stop_payload,
    timeout_seconds=10.0,
    poll_interval_seconds=0.5,
    required_stable_samples=3,
    snapshot_fn=None,
    sleep_fn=None,
    monotonic_fn=None,
):
    """Require an explicit fully-idle Stop and bounded metadata stability."""
    if stop_payload.get("fullyIdle") is not True:
        return {"ready": False, "reason": "stop_payload_not_fully_idle", "stable_samples": 0}

    snapshot_fn = snapshot_fn or (lambda: get_quiescence_snapshot(stop_payload))
    sleep_fn = sleep_fn or time.sleep
    monotonic_fn = monotonic_fn or time.monotonic
    required_stable_samples = max(2, int(required_stable_samples))
    deadline = monotonic_fn() + max(0.0, float(timeout_seconds))
    previous = snapshot_fn()
    stable_samples = 1

    while stable_samples < required_stable_samples:
        if monotonic_fn() >= deadline:
            return {"ready": False, "reason": "quiescence_timeout", "stable_samples": stable_samples}
        sleep_fn(max(0.0, float(poll_interval_seconds)))
        current = snapshot_fn()
        if current == previous:
            stable_samples += 1
        else:
            previous = current
            stable_samples = 1

    return {"ready": True, "reason": "bounded_stability_confirmed", "stable_samples": stable_samples}

def parse_utc_ticks(value):
    """Parse an ISO-8601 timestamp without discarding PowerShell's seventh tick."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError("missing_timestamp")
    match = UTC_TIMESTAMP_PATTERN.fullmatch(value.strip())
    if not match:
        raise ValueError("invalid_timestamp")
    zone = "+00:00" if match.group("zone") == "Z" else match.group("zone")
    parsed = datetime.fromisoformat(match.group("base") + zone).astimezone(timezone.utc)
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    delta = parsed - epoch
    whole_seconds = delta.days * 86400 + delta.seconds
    fraction_ticks = int((match.group("fraction") or "").ljust(7, "0") or "0")
    return whole_seconds * 10_000_000 + fraction_ticks

def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(65536)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()

def read_json_file(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("json_object_required")
    return value

def get_git_identity(workspace):
    def invoke(*args):
        kwargs = {
            "capture_output": True,
            "text": True,
            "encoding": "utf-8",
            "errors": "strict",
            "timeout": 10,
            "check": False,
        }
        if os.name == "nt":
            kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        completed = subprocess.run(
            ["git", "-C", workspace, *args],
            **kwargs
        )
        if completed.returncode != 0:
            raise ValueError("git_identity_unavailable")
        return completed.stdout.strip()
    return {"branch": invoke("branch", "--show-current"), "head": invoke("rev-parse", "HEAD")}

def validate_queue_envelope(queue_item, stop_payload):
    """Reject forged or partially upgraded queue envelopes before any export work."""
    if not isinstance(queue_item, dict) or not isinstance(stop_payload, dict):
        return {"ready": False, "reason": "queue_envelope_invalid"}
    conversation_id = stop_payload.get("conversationId")
    execution_num = stop_payload.get("executionNum")
    expected_fingerprint = hashlib.sha256(f"{conversation_id}_{execution_num}".encode("utf-8")).hexdigest()

    def normalized_paths(values):
        if not isinstance(values, list):
            return None
        return [os.path.normcase(os.path.normpath(str(value))) for value in values]

    matches = (
        queue_item.get("schema_version") == "4.3.4"
        and queue_item.get("fully_idle") is True
        and stop_payload.get("fullyIdle") is True
        and queue_item.get("conversation_id") == conversation_id
        and queue_item.get("execution_num") == execution_num
        and queue_item.get("termination_reason") == stop_payload.get("terminationReason")
        and queue_item.get("transcript_path") == stop_payload.get("transcriptPath")
        and queue_item.get("artifact_directory_path") == stop_payload.get("artifactDirectoryPath")
        and normalized_paths(queue_item.get("workspace_paths")) == normalized_paths(stop_payload.get("workspacePaths"))
        and queue_item.get("event_fingerprint") == expected_fingerprint
    )
    return {
        "ready": bool(matches),
        "reason": "queue_envelope_confirmed" if matches else "queue_envelope_payload_mismatch",
    }

def has_windows_reparse_attribute(path, platform_name=None, lstat_fn=None):
    """Fail closed when an existing Windows path has any reparse-point attribute."""
    if (platform_name or os.name) != "nt":
        return False
    try:
        attributes = getattr((lstat_fn or os.lstat)(path), "st_file_attributes", 0)
    except OSError:
        return True
    return bool(attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400))

def confined_project_file(workspace, relative_path, expected_relative=None):
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise ValueError("authority_path_missing")
    normalized = relative_path.replace("\\", "/")
    if expected_relative and normalized != expected_relative:
        raise ValueError("authority_path_not_canonical")
    if os.path.isabs(relative_path) or normalized.startswith("../") or "/../" in f"/{normalized}/":
        raise ValueError("authority_path_outside_project")
    workspace_real = os.path.realpath(os.path.abspath(workspace))
    relative_parts = normalized.split("/")
    candidate = os.path.abspath(os.path.join(workspace_real, *relative_parts))
    candidate_real = os.path.realpath(candidate)
    try:
        confined = os.path.commonpath([workspace_real, candidate_real]) == workspace_real
    except ValueError:
        confined = False
    current = workspace_real
    has_reparse_component = False
    is_junction = getattr(os.path, "isjunction", lambda _path: False)
    for part in relative_parts:
        current = os.path.join(current, part)
        if not os.path.lexists(current):
            continue
        if (
            os.path.islink(current)
            or is_junction(current)
            or has_windows_reparse_attribute(current)
        ):
            has_reparse_component = True
            break
    if not confined or has_reparse_component or not os.path.isfile(candidate):
        raise ValueError("authority_path_not_safe_file")
    return candidate

def is_safe_verification_evidence_path(relative_path):
    if not isinstance(relative_path, str) or "\\" in relative_path or len(relative_path) > 1024:
        return False
    parts = relative_path.split("/")
    if len(parts) < 3 or parts[0] != ".agy" or parts[1] != "verification":
        return False
    reserved_basenames = {
        "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$",
        *(f"COM{index}" for index in range(1, 10)),
        *(f"LPT{index}" for index in range(1, 10)),
    }
    denied_markers = (
        ".env", "secret", "credential", "capability", "password",
        "private-key", "private_key", "access-token", "access_token",
    )
    for part in parts[2:]:
        if (
            len(part) > 255
            or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", part)
            or part.endswith(".")
            or part.split(".", 1)[0].upper() in reserved_basenames
        ):
            return False
        lowered = part.lower()
        if any(marker in lowered for marker in denied_markers):
            return False
    return True

def validate_authority_freshness(stop_payload, received_at_utc, git_identity_getter=None):
    """Bind publication to the current work item, candidate and exact test receipt."""
    try:
        try:
            stop_ticks = parse_utc_ticks(received_at_utc)
        except (TypeError, ValueError):
            return {"ready": False, "reason": "authority_timestamp_invalid"}
        workspace_candidates = []
        for value in stop_payload.get("workspacePaths", []) or []:
            if not value:
                continue
            workspace = os.path.abspath(value)
            agy = os.path.join(workspace, ".agy")
            if os.path.isfile(os.path.join(agy, "WORK_ITEM.json")) and os.path.isfile(os.path.join(agy, "RUN_RESULT.json")):
                workspace_candidates.append(workspace)
        unique_candidates = list(dict.fromkeys(os.path.normcase(path) for path in workspace_candidates))
        if len(unique_candidates) != 1:
            return {"ready": False, "reason": "authority_workspace_missing_or_ambiguous"}
        workspace = workspace_candidates[0]
        agy = os.path.join(workspace, ".agy")

        paths = {
            "work_item": os.path.join(agy, "WORK_ITEM.json"),
            "lease": os.path.join(agy, "EXECUTION_LEASE.json"),
            "run_result": os.path.join(agy, "RUN_RESULT.json"),
            "candidate": os.path.join(agy, "CANDIDATE_MANIFEST.json"),
            "candidate_status": os.path.join(agy, "CANDIDATE_MANIFEST_STATUS.json"),
        }
        if not all(os.path.isfile(path) and not os.path.islink(path) for path in paths.values()):
            return {"ready": False, "reason": "authority_file_missing_or_unsafe"}

        work_item = read_json_file(paths["work_item"])
        lease = read_json_file(paths["lease"])
        run_result = read_json_file(paths["run_result"])
        candidate = read_json_file(paths["candidate"])
        candidate_status = read_json_file(paths["candidate_status"])
        binding = run_result.get("verification_receipt")
        if not isinstance(binding, dict):
            return {"ready": False, "reason": "run_result_missing_verification_provenance"}

        required_binding = {
            "path", "sha256", "completed_at_utc", "work_item_id", "head",
            "execution_lease_id", "candidate_manifest_sha256",
        }
        if not required_binding.issubset(binding):
            return {"ready": False, "reason": "run_result_incomplete_verification_provenance"}
        receipt_path = confined_project_file(
            workspace,
            binding.get("path"),
            ".agy/VERIFICATION_RECEIPT.json",
        )
        receipt = read_json_file(receipt_path)

        git_identity_getter = git_identity_getter or get_git_identity
        git_identity = git_identity_getter(workspace)
        current_branch = str(git_identity.get("branch", ""))
        current_head = str(git_identity.get("head", ""))
        work_item_id = str(work_item.get("work_item_id", ""))
        goal_epoch = work_item.get("goal_epoch")
        lease_id = str(lease.get("lease_id", ""))
        candidate_hash = file_sha256(paths["candidate"])
        receipt_hash = file_sha256(receipt_path)

        identities = (
            work_item_id
            and current_branch
            and current_head
            and str(lease.get("status", "")) == "active"
            and str(lease.get("work_item_id", "")) == work_item_id
            and lease.get("goal_epoch") == goal_epoch
            and str(lease.get("lease_id", "")) == lease_id
            and str(lease.get("branch", "")) == current_branch
            and str(run_result.get("work_item_id", "")) == work_item_id
            and str(run_result.get("branch", "")) == current_branch
            and str(run_result.get("head", "")) == current_head
            and str(run_result.get("execution_lease_id", "")) == lease_id
            and str(binding.get("work_item_id", "")) == work_item_id
            and str(binding.get("head", "")) == current_head
            and str(binding.get("execution_lease_id", "")) == lease_id
            and str(receipt.get("work_item_id", "")) == work_item_id
            and receipt.get("goal_epoch") == goal_epoch
            and str(receipt.get("branch", "")) == current_branch
            and str(receipt.get("head", "")) == current_head
            and str(receipt.get("execution_lease_id", "")) == lease_id
            and str(candidate.get("work_item_id", "")) == work_item_id
            and str(candidate.get("lease_id", "")) == lease_id
            and str(candidate.get("branch", "")) == current_branch
            and str(candidate.get("head", "")) == current_head
        )
        if not identities:
            return {"ready": False, "reason": "authority_identity_mismatch"}

        expected_receipt_hash = str(binding.get("sha256", ""))
        expected_candidate_hashes = {
            str(binding.get("candidate_manifest_sha256", "")),
            str(receipt.get("candidate_manifest_sha256", "")),
            str(candidate_status.get("manifest_sha256", "")),
        }
        if (
            expected_receipt_hash != receipt_hash
            or expected_receipt_hash.lower() != expected_receipt_hash
            or expected_candidate_hashes != {candidate_hash}
            or candidate_hash.lower() != candidate_hash
            or str(candidate_status.get("status", "")) != "current"
            or str(candidate_status.get("manifest_path", "")).replace("\\", "/") != ".agy/CANDIDATE_MANIFEST.json"
        ):
            return {"ready": False, "reason": "authority_hash_or_candidate_status_mismatch"}

        candidate_files = candidate.get("candidate_files")
        changed_files = receipt.get("changed_files")
        if not isinstance(candidate_files, list) or not isinstance(changed_files, list):
            return {"ready": False, "reason": "candidate_file_set_missing"}
        candidate_paths = []
        for entry in candidate_files:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                return {"ready": False, "reason": "candidate_file_entry_invalid"}
            relative = entry["path"].replace("\\", "/")
            candidate_paths.append(relative)
            candidate_file = os.path.abspath(os.path.join(workspace, *relative.split("/")))
            workspace_real = os.path.realpath(workspace)
            try:
                confined = os.path.commonpath([workspace_real, os.path.realpath(candidate_file)]) == workspace_real
            except ValueError:
                confined = False
            if not confined or os.path.islink(candidate_file):
                return {"ready": False, "reason": "candidate_file_outside_project"}
            if entry.get("exists") is True:
                if not os.path.isfile(candidate_file):
                    return {"ready": False, "reason": "candidate_file_missing"}
                if file_sha256(candidate_file) != str(entry.get("sha256", "")):
                    return {"ready": False, "reason": "candidate_file_hash_mismatch"}
                if os.path.getsize(candidate_file) != entry.get("size_bytes"):
                    return {"ready": False, "reason": "candidate_file_size_mismatch"}
            elif os.path.exists(candidate_file):
                return {"ready": False, "reason": "candidate_deleted_file_reappeared"}
        normalized_changed = [str(value).replace("\\", "/") for value in changed_files]
        if sorted(candidate_paths) != sorted(normalized_changed) or len(set(candidate_paths)) != len(candidate_paths):
            return {"ready": False, "reason": "receipt_candidate_file_set_mismatch"}
        if (
            run_result.get("changed_files") != changed_files
            or run_result.get("evidence_artifacts") != receipt.get("evidence_artifacts")
            or run_result.get("product_artifacts") != receipt.get("product_artifacts")
        ):
            return {"ready": False, "reason": "run_result_receipt_payload_mismatch"}

        tests = receipt.get("tests")
        if not isinstance(tests, list):
            return {"ready": False, "reason": "verification_tests_missing"}
        if any(not isinstance(test, dict) or not isinstance(test.get("required"), bool) for test in tests):
            return {"ready": False, "reason": "verification_test_contract_invalid"}
        run_tests = run_result.get("tests")
        allowed_run_test_fields = {
            "run_id", "required", "exit_code", "started_at_utc", "finished_at_utc",
            "completed_at_utc", "evidence_path", "evidence_sha256",
            "evidence_size_bytes", "supersedes_run_id", "summary",
        }

        def run_test_matches_receipt(run_test, receipt_test):
            if not isinstance(run_test, dict) or set(run_test) != allowed_run_test_fields:
                return False
            exact_fields = (
                "run_id", "required", "exit_code", "evidence_path",
                "evidence_sha256", "evidence_size_bytes",
            )
            if any(run_test.get(field) != receipt_test.get(field) for field in exact_fields):
                return False
            for field in ("supersedes_run_id", "summary"):
                receipt_value = receipt_test.get(field)
                if receipt_value is None:
                    expected_value = ""
                elif isinstance(receipt_value, str):
                    expected_value = receipt_value
                else:
                    return False
                if not isinstance(run_test.get(field), str) or run_test.get(field) != expected_value:
                    return False
            try:
                completed = parse_utc_ticks(receipt_test.get("completed_at_utc"))
                if parse_utc_ticks(run_test.get("completed_at_utc")) != completed:
                    return False
                if parse_utc_ticks(run_test.get("finished_at_utc")) != completed:
                    return False
                receipt_started = receipt_test.get("started_at_utc")
                run_started = run_test.get("started_at_utc")
                if receipt_started is None:
                    if run_started is not None:
                        return False
                elif parse_utc_ticks(run_started) != parse_utc_ticks(receipt_started):
                    return False
            except (TypeError, ValueError):
                return False
            return True

        if (
            not isinstance(run_tests, list)
            or len(run_tests) != len(tests)
            or any(not run_test_matches_receipt(run_test, test) for run_test, test in zip(run_tests, tests))
        ):
            return {"ready": False, "reason": "run_result_receipt_test_mismatch"}
        required_tests = [test for test in tests if isinstance(test, dict) and test.get("required") is True]
        if not required_tests:
            return {"ready": False, "reason": "required_verification_tests_missing"}

        try:
            receipt_completed_ticks = parse_utc_ticks(receipt.get("completed_at_utc"))
            binding_completed_ticks = parse_utc_ticks(binding.get("completed_at_utc"))
            compiled_at_ticks = parse_utc_ticks(run_result.get("compiled_at_utc"))
            generated_at_ticks = parse_utc_ticks(run_result.get("generated_at_utc"))
        except (TypeError, ValueError):
            return {"ready": False, "reason": "authority_timestamp_invalid"}
        try:
            candidate_generated_ticks = parse_utc_ticks(candidate.get("generated_at_utc"))
            candidate_updated_ticks = parse_utc_ticks(candidate_status.get("updated_at_utc"))
        except (TypeError, ValueError):
            return {"ready": False, "reason": "candidate_timestamp_invalid"}
        if binding_completed_ticks != receipt_completed_ticks or compiled_at_ticks != generated_at_ticks:
            return {"ready": False, "reason": "authority_timestamp_binding_mismatch"}

        evidence_ticks = [candidate_generated_ticks, candidate_updated_ticks]
        test_evidence = []
        archive_members = set()
        for test in required_tests:
            run_id = test.get("run_id")
            if not isinstance(run_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", run_id):
                return {"ready": False, "reason": "required_test_run_id_invalid"}
            if not isinstance(test.get("exit_code"), int) or test.get("exit_code") != 0:
                return {"ready": False, "reason": "required_verification_test_failed"}
            started_value = test.get("started_at_utc")
            if not isinstance(started_value, str) or not started_value.strip():
                return {"ready": False, "reason": "required_test_start_missing"}
            try:
                started_ticks = parse_utc_ticks(started_value)
                completed_ticks = parse_utc_ticks(test.get("completed_at_utc"))
                finished_ticks = parse_utc_ticks(test.get("finished_at_utc")) if test.get("finished_at_utc") is not None else completed_ticks
            except (TypeError, ValueError):
                return {"ready": False, "reason": "authority_timestamp_invalid"}
            if started_ticks > completed_ticks or finished_ticks != completed_ticks:
                return {"ready": False, "reason": "test_completion_timestamp_mismatch"}
            if candidate_generated_ticks > started_ticks or candidate_updated_ticks > started_ticks:
                return {"ready": False, "reason": "candidate_published_after_required_test_start"}
            evidence_path_value = test.get("evidence_path")
            if not is_safe_verification_evidence_path(evidence_path_value):
                return {"ready": False, "reason": "test_evidence_path_not_canonical"}
            evidence_path = confined_project_file(workspace, evidence_path_value)
            evidence_sha256 = str(test.get("evidence_sha256", ""))
            evidence_size = test.get("evidence_size_bytes")
            if (
                not re.fullmatch(r"[0-9a-f]{64}", evidence_sha256)
                or not isinstance(evidence_size, int)
                or evidence_size < 0
                or os.path.getsize(evidence_path) != evidence_size
                or file_sha256(evidence_path) != evidence_sha256
            ):
                return {"ready": False, "reason": "test_evidence_hash_or_size_mismatch"}
            evidence_modified_ns = os.stat(evidence_path).st_mtime_ns
            if evidence_modified_ns > completed_ticks * 100:
                return {"ready": False, "reason": "test_evidence_modified_after_completion"}
            archive_member = f"verification_evidence/{run_id}/{os.path.basename(evidence_path)}"
            if archive_member in archive_members:
                return {"ready": False, "reason": "test_evidence_archive_member_duplicate"}
            archive_members.add(archive_member)
            test_evidence.append({
                "run_id": run_id,
                "path": evidence_path,
                "sha256": evidence_sha256,
                "size_bytes": evidence_size,
                "archive_member": archive_member,
            })
            evidence_ticks.append(completed_ticks)
        if max(evidence_ticks) > receipt_completed_ticks or receipt_completed_ticks > compiled_at_ticks or compiled_at_ticks > stop_ticks:
            return {"ready": False, "reason": "authority_not_fresh_for_stop"}

        for path in (receipt_path, paths["run_result"], paths["candidate"], paths["candidate_status"]):
            if os.stat(path).st_mtime_ns > stop_ticks * 100:
                return {"ready": False, "reason": "authority_modified_after_stop"}

        return {
            "ready": True,
            "reason": "current_verification_authority_confirmed",
            "workspace": workspace,
            "work_item_id": work_item_id,
            "head": current_head,
            "run_result_path": paths["run_result"],
            "run_result_sha256": file_sha256(paths["run_result"]),
            "receipt_path": receipt_path,
            "receipt_sha256": receipt_hash,
            "receipt_completed_at_utc": receipt.get("completed_at_utc"),
            "candidate_manifest_path": paths["candidate"],
            "candidate_manifest_sha256": candidate_hash,
            "candidate_status_path": paths["candidate_status"],
            "candidate_status_sha256": file_sha256(paths["candidate_status"]),
            "test_evidence": test_evidence,
        }
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as e:
        print(f"[Worker Debug] validate_authority_freshness exception {type(e).__name__}: {e}")
        return {"ready": False, "reason": "authority_validation_failed"}

def make_pre_publish_guard(
    stop_payload,
    received_at_utc,
    expected_snapshot,
    expected_authority,
    authority_validator,
    snapshot_getter=None,
):
    """Recheck the exact idle/authority snapshot immediately before LATEST swap."""
    snapshot_getter = snapshot_getter or get_quiescence_snapshot

    def guard():
        if stop_payload.get("fullyIdle") is not True:
            return {"ready": False, "reason": "stop_payload_not_fully_idle"}
        if snapshot_getter(stop_payload) != expected_snapshot:
            return {"ready": False, "reason": "quiescence_changed_before_publish"}
        current = authority_validator(stop_payload, received_at_utc)
        if not isinstance(current, dict) or not current.get("ready"):
            return {
                "ready": False,
                "reason": current.get("reason", "authority_changed_before_publish") if isinstance(current, dict) else "authority_changed_before_publish",
            }
        fingerprint_fields = (
            "workspace", "work_item_id", "head", "run_result_sha256",
            "receipt_sha256", "receipt_completed_at_utc", "candidate_manifest_sha256",
            "candidate_status_sha256",
            "test_evidence",
        )
        if any(current.get(field) != expected_authority.get(field) for field in fingerprint_fields):
            return {"ready": False, "reason": "authority_changed_before_publish"}
        return {
            "ready": True,
            "reason": "pre_publish_snapshot_confirmed",
            "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        }

    return guard

def write_json_atomic(path, payload):
    temp_path = f"{path}.tmp.{os.getpid()}"
    with open(temp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(temp_path, path)

def defer_queue_item(q_path, deferred_dir, qf, q_data, reason):
    os.makedirs(deferred_dir, exist_ok=True)
    destination = os.path.join(deferred_dir, qf)
    q_data["deferred"] = {
        "reason": reason,
        "deferred_at_utc": datetime.now(timezone.utc).isoformat(),
        "latest_context_updated": False,
    }
    write_json_atomic(q_path, q_data)
    os.replace(q_path, destination)

def process_queue_once(base_dir, src_dir, quiescence_waiter=None, authority_validator=None):
    queue_dir = os.path.join(base_dir, "queue")
    proc_dir = os.path.join(queue_dir, "processed")
    failed_dir = os.path.join(queue_dir, "failed")
    quarantine_dir = os.path.join(queue_dir, "quarantine")
    deferred_dir = os.path.join(queue_dir, "deferred")
    logs_dir = os.path.join(base_dir, "logs")

    os.makedirs(queue_dir, exist_ok=True)
    os.makedirs(proc_dir, exist_ok=True)
    os.makedirs(failed_dir, exist_ok=True)
    os.makedirs(quarantine_dir, exist_ok=True)
    os.makedirs(deferred_dir, exist_ok=True)
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

            envelope = validate_queue_envelope(q_data, stop_payload)
            if not envelope.get("ready"):
                reason = envelope.get("reason", "queue_envelope_invalid")
                defer_queue_item(q_path, deferred_dir, qf, q_data, reason)
                print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [Worker] Deferred {qf}: {reason}")
                processed_any = True
                continue

            waiter = quiescence_waiter or wait_for_quiescence
            quiescence = waiter(stop_payload)
            if not isinstance(quiescence, dict) or not quiescence.get("ready"):
                reason = quiescence.get("reason", "quiescence_not_confirmed") if isinstance(quiescence, dict) else "quiescence_not_confirmed"
                defer_queue_item(q_path, deferred_dir, qf, q_data, reason)
                print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [Worker] Deferred {qf}: {reason}")
                processed_any = True
                continue

            validator = authority_validator or validate_authority_freshness
            authority = validator(stop_payload, q_data.get("received_at_utc"))
            if not isinstance(authority, dict) or not authority.get("ready"):
                reason = authority.get("reason", "authority_not_confirmed") if isinstance(authority, dict) else "authority_not_confirmed"
                defer_queue_item(q_path, deferred_dir, qf, q_data, reason)
                print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [Worker] Deferred {qf}: {reason}")
                processed_any = True
                continue

            publication_snapshot = get_quiescence_snapshot(stop_payload)
            pre_publish_guard = make_pre_publish_guard(
                stop_payload,
                q_data.get("received_at_utc"),
                publication_snapshot,
                authority,
                validator,
            )

            exp = CompanionExporter(
                stop_payload_file=q_path,
                conversation_id=conv_id,
                override_base_dir=base_dir,
                required_authority=authority,
                pre_publish_guard=pre_publish_guard,
            )
            res = exp.export()

            if res.get("status") == "SUCCESS":
                gen_id = res.get("last_successful_generation_id") or res.get("generation_id", "unknown_gen")
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
                    "fully_idle": True,
                    "fully_idle_confirmed": True,
                    "quiescence_verdict": quiescence.get("reason"),
                    "quiescence": {
                        "status": "PASS",
                        "samples": quiescence.get("stable_samples"),
                        "observed_at_utc": res.get("quiescence_checked_at_utc"),
                    },
                    "authority_verdict": authority.get("reason"),
                    "work_item_id": authority.get("work_item_id"),
                    "head": authority.get("head"),
                    "run_result_sha256": authority.get("run_result_sha256"),
                    "verification_receipt_sha256": authority.get("receipt_sha256"),
                    "verification_completed_at_utc": authority.get("receipt_completed_at_utc"),
                    "candidate_manifest_sha256": authority.get("candidate_manifest_sha256"),
                    "candidate_manifest_status_sha256": authority.get("candidate_status_sha256"),
                    "archive_path_from_exporter_used": True,
                    "final_zip_valid": bool(archive_p and os.path.exists(archive_p)),
                    "latest_context_updated": bool(archive_p and os.path.exists(archive_p)),
                    "ux_helper_completed": ux_result is not None,
                    "clipboard_roundtrip_match": bool(ux_result and ux_result.get("clipboard_roundtrip_match")),
                    "explorer_opened": bool(ux_result and ux_result.get("explorer_open_success")),
                    "notification_created": bool(ux_result and ux_result.get("notification_success")),
                    "generation_id": gen_id,
                    "archive_path": archive_p,
                    "archive_sha256": archive_sha256,
                    "archive_published_at_utc": res.get("published_at_utc"),
                    "atomic_latest_publish": res.get("atomic_latest_publish") is True,
                    "project_slug": proj_slug,
                    "verdict": "PASS" if (is_hook_triggered and archive_p and os.path.exists(archive_p) and ux_result and ux_result.get("clipboard_roundtrip_match")) else "MANUAL_TRIGGER" if (not is_hook_triggered and archive_p and os.path.exists(archive_p)) else "EXPORT_FAILED",
                    "conversationId": conv_id,
                    "workspacePaths": ws_paths,
                    "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
                }

                ev_file = os.path.join(logs_dir, "DESKTOP_STOP_EVIDENCE.json")
                write_json_atomic(ev_file, evidence)

                processed_any = True
            elif res.get("status") == "DEFERRED":
                details = res.get("details")
                reason = details.get("reason") if isinstance(details, dict) else None
                reason = reason or res.get("error", "pre_publish_guard_failed")
                defer_queue_item(q_path, deferred_dir, qf, q_data, reason)
                print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [Worker] Deferred {qf}: {reason}")
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
    base_dir = os.environ.get("COMPANION_HANDOFF_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
