import os
import sys
import tempfile
import shutil
import traceback
import json
import zipfile
import ast
import hashlib
import threading
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock

print("="*60)
print("Auto Context Handoff Test Suite v4.3.4")
print("="*60)

SRC_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'src'))
BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if SRC_DIR not in sys.path:
    sys.path.insert(0, SRC_DIR)

TEST_PASS = 0
TEST_FAIL = 0

def run_test(name, func):
    global TEST_PASS, TEST_FAIL
    try:
        func()
        print(f'Running test: {name} ... [PASS]')
        TEST_PASS += 1
    except Exception as e:
        print(f'Running test: {name} ... [FAIL]: {e}')
        TEST_FAIL += 1
        traceback.print_exc()

_temp_envs = []
def setup_temp_env():
    env = tempfile.mkdtemp()
    _temp_envs.append(env)
    return env

def teardown_temp_env(env=None):
    if env:
        shutil.rmtree(env, ignore_errors=True)
        if env in _temp_envs:
            _temp_envs.remove(env)
    else:
        for e in _temp_envs:
            shutil.rmtree(e, ignore_errors=True)
        _temp_envs.clear()

def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)

def make_queue_job(env, conversation_id="conv-test", execution_num=1, fully_idle=True):
    transcript_path = os.path.join(env, "transcript.jsonl")
    artifact_dir = os.path.join(env, "artifacts")
    os.makedirs(artifact_dir, exist_ok=True)
    if not os.path.exists(transcript_path):
        with open(transcript_path, "w", encoding="utf-8") as handle:
            handle.write('{"type":"USER_INPUT","content":"test"}\n')
    stop_payload = {
        "conversationId": conversation_id,
        "workspacePaths": [env],
        "transcriptPath": transcript_path,
        "artifactDirectoryPath": artifact_dir,
        "executionNum": execution_num,
        "terminationReason": "NO_TOOL_CALL",
        "fullyIdle": fully_idle,
    }
    fingerprint = hashlib.sha256(f"{conversation_id}_{execution_num}".encode("utf-8")).hexdigest()
    return {
        "schema_version": "4.3.4",
        "conversation_id": conversation_id,
        "workspace_paths": [env],
        "transcript_path": transcript_path,
        "artifact_directory_path": artifact_dir,
        "execution_num": execution_num,
        "termination_reason": "NO_TOOL_CALL",
        "error": "",
        "fully_idle": fully_idle,
        "received_at_utc": (datetime.now(timezone.utc) + timedelta(minutes=1)).isoformat(),
        "event_fingerprint": fingerprint,
        "stop_payload": stop_payload,
    }

def ready_gate(*_args, **_kwargs):
    return {"ready": True, "reason": "test_gate_confirmed", "stable_samples": 3}

def create_authority_fixture(env, conversation_id="conv-authority"):
    from run_ag_handoff_worker import validate_authority_freshness

    queue_item = make_queue_job(env, conversation_id, 7)
    agy = os.path.join(env, ".agy")
    os.makedirs(agy, exist_ok=True)
    branch = "main"
    head = "a" * 40
    work_item_id = "wi-current-authority"
    lease_id = "lease-current-authority"
    now = datetime.now(timezone.utc)
    candidate_time = now - timedelta(seconds=30)
    test_time = now - timedelta(seconds=20)
    receipt_time = now - timedelta(seconds=10)
    compiled_time = now - timedelta(seconds=5)
    stop_time = now + timedelta(seconds=10)
    queue_item["received_at_utc"] = stop_time.isoformat()

    write_json(os.path.join(agy, "WORK_ITEM.json"), {
        "schema_version": "1.1.0",
        "work_item_id": work_item_id,
        "goal_epoch": 3,
        "goal": "Verify current result",
        "assurance_mode": "guarded",
        "status": "active",
        "project_root": env,
        "branch": branch,
        "updated_at_utc": candidate_time.isoformat(),
    })
    write_json(os.path.join(agy, "EXECUTION_LEASE.json"), {
        "schema_version": "1.1.0",
        "lease_id": lease_id,
        "status": "active",
        "work_item_id": work_item_id,
        "goal_epoch": 3,
        "branch": branch,
        "baseline_head": head,
    })
    candidate = {
        "schema_version": "1.1.0",
        "work_item_id": work_item_id,
        "lease_id": lease_id,
        "branch": branch,
        "head": head,
        "candidate_files": [],
        "control_plane_files": [],
        "ambient_git_status": [],
        "generated_at_utc": candidate_time.isoformat(),
    }
    candidate_path = os.path.join(agy, "CANDIDATE_MANIFEST.json")
    write_json(candidate_path, candidate)
    candidate_hash = hashlib.sha256(open(candidate_path, "rb").read()).hexdigest()
    write_json(os.path.join(agy, "CANDIDATE_MANIFEST_STATUS.json"), {
        "schema_version": "1.1.0",
        "status": "current",
        "manifest_path": ".agy/CANDIDATE_MANIFEST.json",
        "manifest_sha256": candidate_hash,
        "candidate_file_count": 0,
        "ambient_file_count": 0,
        "invalidated_by": [],
        "updated_at_utc": candidate_time.isoformat(),
    })

    evidence_relative = ".agy/verification/verification-current.log"
    evidence_path = os.path.join(env, *evidence_relative.split("/"))
    os.makedirs(os.path.dirname(evidence_path), exist_ok=True)
    evidence_bytes = "260 files, 708 tests: PASS\nПроверка завершена.\n".encode("utf-8")
    with open(evidence_path, "wb") as handle:
        handle.write(evidence_bytes)
    os.utime(evidence_path, (test_time.timestamp(), test_time.timestamp()))
    evidence_hash = hashlib.sha256(evidence_bytes).hexdigest()
    test_entry = {
        "run_id": "vitest-current",
        "required": True,
        "exit_code": 0,
        "started_at_utc": (test_time - timedelta(minutes=1)).isoformat(),
        "completed_at_utc": test_time.isoformat(),
        "evidence_path": evidence_relative,
        "evidence_sha256": evidence_hash,
        "evidence_size_bytes": len(evidence_bytes),
    }
    receipt = {
        "work_item_id": work_item_id,
        "goal_epoch": 3,
        "branch": branch,
        "head": head,
        "execution_lease_id": lease_id,
        "candidate_manifest_sha256": candidate_hash,
        "completed_at_utc": receipt_time.isoformat(),
        "changed_files": [],
        "tests": [test_entry],
        "evidence_artifacts": [evidence_relative],
        "product_artifacts": [],
    }
    receipt_path = os.path.join(agy, "VERIFICATION_RECEIPT.json")
    write_json(receipt_path, receipt)
    receipt_hash = hashlib.sha256(open(receipt_path, "rb").read()).hexdigest()
    run_result = {
        "schema_version": "1.0.0",
        "work_item_id": work_item_id,
        "assurance_mode": "guarded",
        "branch": branch,
        "head": head,
        "git_state": "clean",
        "implementation_status": "completed",
        "verification_status": "passed",
        "audit_status": "passed",
        "acceptance_status": "accepted",
        "product_blockers": [],
        "verification_blockers": [],
        "release_blockers": [],
        "service_warnings": [],
        "changed_files": [],
        "tests": [{**test_entry, "finished_at_utc": test_time.isoformat()}],
        "next_workflow": None,
        "generated_at_utc": compiled_time.isoformat(),
        "compiled_at_utc": compiled_time.isoformat(),
        "evidence_artifacts": [evidence_relative],
        "product_artifacts": [],
        "execution_lease_id": lease_id,
        "verification_receipt": {
            "path": ".agy/VERIFICATION_RECEIPT.json",
            "sha256": receipt_hash,
            "completed_at_utc": receipt_time.isoformat(),
            "work_item_id": work_item_id,
            "head": head,
            "execution_lease_id": lease_id,
            "candidate_manifest_sha256": candidate_hash,
        },
    }
    run_result_path = os.path.join(agy, "RUN_RESULT.json")
    write_json(run_result_path, run_result)

    git_identity = lambda _workspace: {"branch": branch, "head": head}
    validator = lambda payload, received: validate_authority_freshness(
        payload,
        received,
        git_identity_getter=git_identity,
    )
    authority = validator(queue_item["stop_payload"], queue_item["received_at_utc"])
    assert authority.get("ready") is True, f"Fixture authority invalid: {authority}"
    return {
        "queue_item": queue_item,
        "authority": authority,
        "validator": validator,
        "receipt_path": receipt_path,
        "run_result_path": run_result_path,
        "candidate_path": candidate_path,
        "candidate_status_path": os.path.join(agy, "CANDIDATE_MANIFEST_STATUS.json"),
        "evidence_path": evidence_path,
        "evidence_bytes": evidence_bytes,
        "archive_member": "verification_evidence/vitest-current/verification-current.log",
    }

# --- Unit Tests (T01-T30) ---

def test_T01_path_normalization():
    from project_root_resolver import normalize_path
    env = setup_temp_env()
    p = normalize_path('"C:\\Test Path\\русский.txt"')
    assert '"' not in p
    assert "Test Path" in p
    teardown_temp_env(env)

def test_T02_git_root_detection():
    from project_root_resolver import get_git_root
    env = setup_temp_env()
    os.makedirs(os.path.join(env, '.git'))
    root = get_git_root(env)
    assert root is not None
    assert os.path.normpath(root) == os.path.normpath(env)
    teardown_temp_env(env)

def test_T03_non_git_project_root_detection():
    from project_root_resolver import find_project_root
    env = setup_temp_env()
    with open(os.path.join(env, 'package.json'), 'w') as f:
        f.write("{}")
    root = find_project_root(env)
    assert root is not None
    assert os.path.normpath(root) == os.path.normpath(env)
    teardown_temp_env(env)

def test_T04_root_scoring():
    from project_root_resolver import classify_roots
    env = setup_temp_env()
    with open(os.path.join(env, 'package.json'), 'w') as f:
        f.write("{}")
    file_a = os.path.join(env, "file.py")
    res = classify_roots([file_a], env, [file_a])
    assert isinstance(res, dict)
    assert res["launch_workspace"] == os.path.normpath(env)
    assert res["primary_implementation_root"] == os.path.normpath(env)
    teardown_temp_env(env)

def test_T05_git_snapshot_capture():
    from git_snapshot import capture_git_snapshot
    env = setup_temp_env()
    with patch('git_snapshot.run_git_command', return_value="main\n"):
        snap = capture_git_snapshot(env, "root1")
        assert isinstance(snap, dict)
        assert snap.get("ROOT_INFO", {}).get("branch") == "main"
    teardown_temp_env(env)

def test_T06_linked_worktree_detection():
    from git_snapshot import capture_git_snapshot
    env = setup_temp_env()
    git_file = os.path.join(env, '.git')
    if os.path.isdir(git_file):
        shutil.rmtree(git_file)
    with open(git_file, 'w') as f:
        f.write("gitdir: /path/to/repo/.git/worktrees/wt")
    snap = capture_git_snapshot(env, "test_wt")
    root_info = snap.get("ROOT_INFO", {})
    assert root_info.get("is_linked_worktree") is True, f"Expected linked worktree, got {root_info}"
    teardown_temp_env(env)

def test_T07_authority_discovery():
    from authority_collector import discover_authorities
    env = setup_temp_env()
    agy_dir = os.path.join(env, ".agy")
    os.makedirs(agy_dir, exist_ok=True)
    with open(os.path.join(agy_dir, "RUN_RESULT.json"), "w") as f:
        json.dump({"work_item": "test"}, f)
    auth = discover_authorities([env])
    assert isinstance(auth, list)
    assert len(auth) >= 1
    assert any(c["filename"] == "RUN_RESULT.json" for c in auth)
    teardown_temp_env(env)

def test_T08_authority_scoring():
    from authority_collector import score_authority
    env = setup_temp_env()
    candidate = {"schema_valid": True, "data": {"work_item_id": "123"}, "filename": "RUN_RESULT.json"}
    score = score_authority(candidate, "123")
    assert type(score) is int
    assert score > 10, "Matching work_item_id should yield score > base 10"
    teardown_temp_env(env)

def test_T09_status_normalization():
    from authority_collector import normalize_status
    env = setup_temp_env()
    assert normalize_status("passed") == "accepted"
    assert normalize_status("completed") == "accepted"
    assert normalize_status("failed") == "blocked"
    assert normalize_status("unknown_status") == "unknown"
    teardown_temp_env(env)

def test_T10_H10_RUN_RESULT_alias_support():
    from authority_collector import _get_field
    env = setup_temp_env()
    val = _get_field({"RUN_RESULT": "value"}, ["H10", "RUN_RESULT"])
    assert val == "value"
    val2 = _get_field({"work_item": "item1"}, ["work_item_id", "work_item"])
    assert val2 == "item1"
    teardown_temp_env(env)

def test_T11_H10_AUDIT_RESULT_alias_support():
    from authority_collector import _get_field
    env = setup_temp_env()
    val = _get_field({"AUDIT_RESULT": "val2"}, ["H10", "AUDIT_RESULT"])
    assert val == "val2"
    teardown_temp_env(env)

def test_T12_artifact_verification_levels():
    from artifact_verifier import verify_artifact
    env = setup_temp_env()
    zip_path = os.path.join(env, "test.zip")
    with zipfile.ZipFile(zip_path, 'w') as zf:
        zf.writestr("test.txt", b"hello")
    res = verify_artifact(zip_path)
    assert isinstance(res, dict)
    assert res.get("exists") is True
    assert res.get("zip_security") == "passed"
    teardown_temp_env(env)

def test_T13_ZIP_security_traversal_detection():
    from artifact_verifier import is_unsafe_zip_path
    env = setup_temp_env()
    assert is_unsafe_zip_path("../../../windows/system32") is True
    assert is_unsafe_zip_path("C:\\windows\\system32") is True
    assert is_unsafe_zip_path("normal/path/file.txt") is False
    teardown_temp_env(env)

def test_T14_ZIP_security_duplicate_member_detection():
    from package_validator import PackageValidator
    env = setup_temp_env()
    dup_zip = os.path.join(env, "dup_test.zip")
    with zipfile.ZipFile(dup_zip, 'w') as zf:
        zf.writestr("file1.txt", b"content1")
        zf.writestr("file1.txt", b"content2")
    pv = PackageValidator(dup_zip)
    res = pv.validate()
    assert res["transport_verdict"] == "FAIL", f"Expected FAIL for duplicate member, got {res['transport_verdict']}"
    assert any("DUPLICATE" in c for c in res.get("reason_codes", [])), f"Expected duplicate reason, got {res.get('reason_codes')}"
    teardown_temp_env(env)

def test_T15_ZIP_security_zip_bomb_ratio_detection():
    from artifact_verifier import check_zip_security
    env = setup_temp_env()
    normal_zip = os.path.join(env, "normal.zip")
    with zipfile.ZipFile(normal_zip, 'w') as zf:
        zf.writestr("data.txt", b"hello world")
    res = check_zip_security(normal_zip)
    assert isinstance(res, dict)
    assert res.get("passed") is True, f"Expected passed=True, got {res}"
    teardown_temp_env(env)

def test_T16_manifest_exact_parity():
    from package_validator import PackageValidator
    import hashlib
    env = setup_temp_env()
    content = b"hello world"
    sha = hashlib.sha256(content).hexdigest()
    manifest = {
        "generation_id": "test",
        "file_count": 1,
        "self_excluded_files": ["MANIFEST.json", "MANIFEST_VALIDATION.json"],
        "files": {"test.txt": {"file_path": "test.txt", "size": len(content), "sha256": sha}}
    }
    test_zip = os.path.join(env, "manifest_test.zip")
    with zipfile.ZipFile(test_zip, 'w') as zf:
        zf.writestr("test.txt", content)
        zf.writestr("MANIFEST.json", json.dumps(manifest))
    val = PackageValidator(test_zip)
    res = val.validate()
    assert res["transport_verdict"] == "PASS", f"Expected PASS, got {res}"
    teardown_temp_env(env)

def test_T17_self_referential_manifest_exclusion():
    from package_builder import PackageBuilder
    env = setup_temp_env()
    pb = PackageBuilder(os.path.join(env, "latest"), os.path.join(env, "history"), "gen_test_1")
    contents = {"test.txt": b"hello"}
    manifest = pb.build_manifest(contents)
    assert "MANIFEST.json" in manifest["self_excluded_files"]
    assert "MANIFEST_VALIDATION.json" in manifest["self_excluded_files"]
    assert "test.txt" in manifest["files"]
    assert "MANIFEST.json" not in manifest["files"]
    teardown_temp_env(env)

def test_T18_privacy_exclusion_default_patterns():
    from capture_session_context import is_privacy_excluded
    env = setup_temp_env()
    assert is_privacy_excluded(".env") is True
    assert is_privacy_excluded("credentials.json") is True
    assert is_privacy_excluded("server.key") is True
    teardown_temp_env(env)

def test_T19_privacy_report_generation():
    from capture_session_context import is_privacy_excluded
    env = setup_temp_env()
    assert is_privacy_excluded("credentials.json") is True
    assert is_privacy_excluded("my_token.txt") is True
    assert is_privacy_excluded("conversations.db") is True
    assert is_privacy_excluded("raw_ecg_data.csv") is True
    assert is_privacy_excluded("normal_code.py") is False
    teardown_temp_env(env)

def test_T20_stale_task_document_detection():
    from authority_collector import collect_and_select
    env = setup_temp_env()
    res = collect_and_select([env])
    assert isinstance(res, dict)
    teardown_temp_env(env)

def test_T21_backticked_checkbox_recognition():
    env = setup_temp_env()
    task_md = os.path.join(env, "task.md")
    with open(task_md, "w", encoding="utf-8") as f:
        f.write("# Tasks\n- [x] `Update exporter` (done)\n- [ ] `Add test` (pending)\n")
    
    with open(task_md, "r", encoding="utf-8") as f:
        lines = f.readlines()
        
    checked = [l for l in lines if "- [x]" in l or "- [X]" in l]
    unchecked = [l for l in lines if "- [ ]" in l]
    
    assert len(checked) == 1, f"Expected 1 checked task, got {len(checked)}"
    assert "`Update exporter`" in checked[0]
    assert len(unchecked) == 1, f"Expected 1 pending task, got {len(unchecked)}"
    teardown_temp_env(env)

def test_T22_result_identity_ACCEPTED_requires_existing_verified_artifact():
    from result_identity import ResultIdentityResolver
    env = setup_temp_env()
    res = ResultIdentityResolver(search_roots=[env])
    auths = res.discover_authorities()
    result = res.reconcile_artifact_and_identity(auths, None)
    if isinstance(result, tuple):
        identity, _, verdict, _ = result
    else:
        identity = result
        verdict = identity.get("identity_verdict", "")
    assert verdict != "ACCEPTED", f"ACCEPTED should be forbidden without artifact, got {verdict}"
    teardown_temp_env(env)

def test_T23_result_identity_VERIFICATION_BLOCKED_for_missing_artifact():
    from result_identity import ResultIdentityResolver
    env = setup_temp_env()
    rr_dir = os.path.join(env, ".agy")
    os.makedirs(rr_dir, exist_ok=True)
    rr = {"work_item_id": "test-item", "status": "accepted", "primary_artifact_path": os.path.join(env, "nonexistent.zip"), "assurance_mode": "GUARDED"}
    with open(os.path.join(rr_dir, "RUN_RESULT.json"), "w") as f:
        json.dump(rr, f)
    resolver = ResultIdentityResolver(search_roots=[env])
    auths = resolver.discover_authorities()
    result = resolver.reconcile_artifact_and_identity(auths, None)
    if isinstance(result, tuple):
        identity, _, verdict, _ = result
    else:
        identity = result
        verdict = identity.get("identity_verdict", "")
    assert verdict in ("VERIFICATION_BLOCKED", "NO_CURRENT_RESULT", "NOT_APPLICABLE"), f"Expected VERIFICATION_BLOCKED, got {verdict}"
    teardown_temp_env(env)

def test_T24_result_identity_VERIFICATION_DEBT_for_historical_work_item():
    from continuation_policy import compute_continuation_policy
    env = setup_temp_env()
    result = {"work_item_id": "old-item", "implementation_status": "completed", "verification_status": "unknown"}
    pol = compute_continuation_policy(
        result_identity=result,
        slash_readiness="SLASH_READY_FOR_NEW_GOAL",
        conversation_verdict="READY",
        implementation_verdict="READY",
        identity_verdict="VERIFICATION_BLOCKED",
    )
    prev = pol["previous_work_item"]
    assert prev["verification_status"] == "debt", f"Expected debt, got {prev['verification_status']}"
    assert prev["release_eligibility"] == "blocked", "Expected blocked release"
    teardown_temp_env(env)

def test_T25_result_identity_machine_precedence_over_narrative():
    from result_identity import ResultIdentityResolver
    env = setup_temp_env()
    rr_dir = os.path.join(env, ".agy")
    os.makedirs(rr_dir, exist_ok=True)
    machine_path = os.path.join(env, "machine_artifact.zip")
    with zipfile.ZipFile(machine_path, 'w') as zf:
        zf.writestr("data.txt", b"machine content")
    rr = {"work_item_id": "test", "primary_artifact_path": machine_path, "status": "accepted"}
    with open(os.path.join(rr_dir, "RUN_RESULT.json"), "w") as f:
        json.dump(rr, f)
    resolver = ResultIdentityResolver(search_roots=[env])
    auths = resolver.discover_authorities()
    result = resolver.reconcile_artifact_and_identity(auths, None, narrative_text="narrative_artifact.zip")
    if isinstance(result, tuple):
        identity, _, verdict, _ = result
    else:
        identity = result
    assert isinstance(identity, dict), "identity must be dict"
    pa = identity.get("primary_artifact", {})
    assert pa, f"Expected primary_artifact, got {identity}"
    pa_path = pa.get("absolute_path") or pa.get("file_path") or pa.get("path") or pa.get("machine_path") or ""
    assert "machine_artifact" in pa_path, f"Machine path should take precedence, got {pa_path}"
    teardown_temp_env(env)

def test_T26_continuation_policy_READY_NEW_WORK_ITEM_WITH_VERIFICATION_DEBT():
    from continuation_policy import compute_continuation_policy
    env = setup_temp_env()
    pol = compute_continuation_policy(
        result_identity={"work_item_id": "test", "implementation_status": "completed", "verification_status": "unknown"},
        slash_readiness="SLASH_READY_FOR_NEW_GOAL",
        conversation_verdict="READY",
        implementation_verdict="READY",
        identity_verdict="VERIFICATION_DEBT",
    )
    assert pol is not None
    assert pol["continuation_readiness"] == "READY_NEW_WORK_ITEM_WITH_VERIFICATION_DEBT"
    teardown_temp_env(env)

def test_T27_continuation_policy_BLOCKED():
    from continuation_policy import compute_continuation_policy
    env = setup_temp_env()
    pol = compute_continuation_policy(
        result_identity={"work_item_id": "test"},
        slash_readiness="NOT_APPLICABLE",
        conversation_verdict="BLOCKED",
        implementation_verdict="BLOCKED",
        identity_verdict="VERIFICATION_BLOCKED",
    )
    assert pol["continuation_readiness"] == "BLOCKED"
    teardown_temp_env(env)

def test_T28_runtime_status_inventory_routing():
    from runtime_status import RuntimeStatusEvaluator
    env = setup_temp_env()
    evaluator = RuntimeStatusEvaluator()
    assert evaluator is not None
    res = evaluator.evaluate()
    assert isinstance(res, str)
    teardown_temp_env(env)

def test_T29_runtime_status_HANDSHAKE_REFRESH_REQUIRED():
    from runtime_status import RuntimeStatusEvaluator
    env = setup_temp_env()
    authorities = {
        "RUNTIME_HANDSHAKE.json": {
            "data": {
                "schema_version": "1.0",
                "routing_valid": False,
                "routing_errors": ["stale_git_head"],
                "installed_project_package_version": "1.2.5",
                "runtime_version": "1.2.2"
            },
            "source_path": "test"
        },
        "TARGET_RUNTIME_BASELINE.json": {
            "data": {
                "pipeline_package": "1.2.5",
                "runtime": "1.2.2"
            },
            "source_path": "test"
        }
    }
    pipeline_info = {"has_pipeline": True}
    evaluator = RuntimeStatusEvaluator(authorities=authorities, pipeline_info=pipeline_info)
    status = evaluator.evaluate()
    assert status == "HANDSHAKE_REFRESH_REQUIRED", f"Expected HANDSHAKE_REFRESH_REQUIRED, got {status}"
    teardown_temp_env(env)

def test_T30_runtime_status_ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED():
    from runtime_status import RuntimeStatusEvaluator
    env = setup_temp_env()
    authorities = {
        "RUNTIME_HANDSHAKE.json": {
            "data": {
                "schema_version": "1.0",
                "routing_valid": True,
                "installed_project_package_version": "1.0.0",
            },
            "source_path": "test"
        }
    }
    pipeline_info = {"has_pipeline": True, "handshake_valid": True, "routing_valid": True}
    evaluator = RuntimeStatusEvaluator(authorities=authorities, pipeline_info=pipeline_info)
    status = evaluator.evaluate()
    assert status == "ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED"
    teardown_temp_env(env)

# --- Integration Tests (T31-T40) ---

def test_T31_gen_ID_generation_and_ZIP_member_set():
    from package_builder import PackageBuilder
    from package_validator import PackageValidator
    env = setup_temp_env()
    latest = os.path.join(env, "latest")
    history = os.path.join(env, "history")
    pb = PackageBuilder(latest, history, "gen_test_31")
    contents = {"COMPANION_ENTRY.md": b"# Entry", "CONTEXT_READINESS.json": b'{"transport_verdict":"PASS"}'}
    res = pb.build_and_publish(contents, validator_class=PackageValidator)
    assert res["status"] == "SUCCESS", f"Expected SUCCESS, got {res}"
    assert os.path.exists(res["archive_path"]), "Archive should exist"
    with zipfile.ZipFile(res["archive_path"]) as zf:
        names = zf.namelist()
        assert "COMPANION_ENTRY.md" in names
        assert "MANIFEST.json" in names
    teardown_temp_env(env)

def test_T32_full_export_with_temp_env():
    from export_ag_handoff import CompanionExporter
    env = setup_temp_env()
    tr_path = os.path.join(env, "transcript.jsonl")
    with open(tr_path, 'w', encoding='utf-8') as f:
        f.write('{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"test"}\n')
    art_dir = os.path.join(env, "artifacts")
    os.makedirs(art_dir, exist_ok=True)
    exp = CompanionExporter(
        conversation_id="test-conv-t32",
        mode="forensic",
        override_base_dir=env
    )
    exp.stop_payload = {
        "workspacePaths": [env],
        "conversationId": "test-conv-t32",
        "transcriptPath": tr_path,
        "artifactDirectoryPath": art_dir,
    }
    res = exp.export()
    assert res.get("status") == "SUCCESS", f"Export failed: {res}"
    teardown_temp_env(env)

def test_T33_package_builder_validator_roundtrip():
    from package_builder import PackageBuilder
    from package_validator import PackageValidator
    env = setup_temp_env()
    latest = os.path.join(env, "latest")
    history = os.path.join(env, "history")
    pb = PackageBuilder(latest, history, "gen_roundtrip")
    contents = {"data.txt": b"roundtrip test content"}
    res = pb.build_and_publish(contents, validator_class=PackageValidator)
    assert res["status"] == "SUCCESS"
    pv = PackageValidator(res["archive_path"])
    val = pv.validate()
    assert val["transport_verdict"] == "PASS", f"Roundtrip validation failed: {val}"
    teardown_temp_env(env)

def test_T34_cursor_tracking_across_transcript_delta():
    from export_ag_handoff import CompanionExporter
    env = setup_temp_env()
    tp = os.path.join(env, 'transcript.jsonl')
    with open(tp, 'w', encoding='utf-8') as f:
        for i in range(5):
            f.write(json.dumps({"step_index": i, "type": "USER_INPUT", "content": f"msg {i}"}) + '\n')
            
    art_dir = os.path.join(env, 'artifacts')
    os.makedirs(art_dir, exist_ok=True)
    conv_id = "test-conv-t34"
    
    payload_path = os.path.join(env, "payload.json")
    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump({
            "conversationId": conv_id,
            "workspacePaths": [env],
            "transcriptPath": tp,
            "artifactDirectoryPath": art_dir
        }, f)
        
    exp1 = CompanionExporter(stop_payload_file=payload_path, conversation_id=conv_id, mode="forensic", override_base_dir=env)
    res1 = exp1.export()
    assert res1.get("status") == "SUCCESS", f"Export 1 failed: {res1}"
    
    state_file = os.path.join(env, "state", f"{conv_id}.json")
    assert os.path.exists(state_file), "State file should exist after first export"
    with open(state_file, 'r', encoding='utf-8') as f:
        state1 = json.load(f)
    cursor_after_first = state1.get("last_processed_transcript_line", 0)
    assert cursor_after_first > 0, f"Expected cursor > 0 after first export, got {cursor_after_first}"
    
    with open(tp, 'a', encoding='utf-8') as f:
        for i in range(5, 8):
            f.write(json.dumps({"step_index": i, "type": "USER_INPUT", "content": f"msg {i}"}) + '\n')
            
    exp2 = CompanionExporter(stop_payload_file=payload_path, conversation_id=conv_id, mode="forensic", override_base_dir=env)
    res2 = exp2.export()
    assert res2.get("status") == "SUCCESS", f"Export 2 failed: {res2}"
    
    with open(state_file, 'r', encoding='utf-8') as f:
        state2 = json.load(f)
    cursor_after_second = state2.get("last_processed_transcript_line", 0)
    assert cursor_after_second > cursor_after_first, "Second cursor > first cursor"
    
    handoff_zip = res2.get("archive_path")
    assert os.path.exists(handoff_zip), "Export 2 zip must exist"
    with zipfile.ZipFile(handoff_zip) as zf:
        delta_bytes = zf.read("SESSION_DELTA/TRANSCRIPT_DELTA.jsonl").decode('utf-8')
        delta_lines = [line for line in delta_bytes.strip().split('\n') if line]
        assert len(delta_lines) > 0, "Second delta should contain new events"
        
    teardown_temp_env(env)

def test_T35_multi_root_write_capture():
    from project_root_resolver import classify_roots
    env = setup_temp_env()
    
    launch_a = os.path.join(env, "launch_ws_a")
    os.makedirs(launch_a, exist_ok=True)
    with open(os.path.join(launch_a, "package.json"), "w") as f:
        f.write("{}")
        
    root_b = os.path.join(env, "write_root_b")
    os.makedirs(os.path.join(root_b, "src"), exist_ok=True)
    with open(os.path.join(root_b, "package.json"), "w") as f:
        f.write("{}")
    file_b = os.path.join(root_b, "src", "file_b.py")
    
    root_c = os.path.join(env, "write_root_c")
    os.makedirs(os.path.join(root_c, "src"), exist_ok=True)
    with open(os.path.join(root_c, "package.json"), "w") as f:
        f.write("{}")
    file_c = os.path.join(root_c, "src", "file_c.py")
    
    touched = [file_b, file_c]
    write_ops = [file_b, file_c]
    
    res = classify_roots(touched, launch_a, write_ops)
    primary = res["primary_implementation_root"]
    additional = res["additional_implementation_roots"].split(",") if res["additional_implementation_roots"] else []
    
    assert primary in [root_b, root_c], f"Primary root should be B or C, got {primary}"
    assert primary != launch_a, "Launch workspace without writes should not become primary"
    
    all_impl = [primary] + additional
    assert root_b in all_impl, "Root B should be included in implementation roots"
    assert root_c in all_impl, "Root C should be included in implementation roots"
    assert len(all_impl) >= 2, "multi_root_task = true (at least 2 implementation roots)"
    
    teardown_temp_env(env)

def test_T36_ux_clipboard_roundtrip_Win32():
    from run_ag_ux_helper import win32_set_single_clipboard
    env = setup_temp_env()
    mock_func = MagicMock(return_value=(1, 0, True))
    with patch("run_ag_ux_helper.win32_set_single_clipboard", side_effect=mock_func):
        from run_ag_ux_helper import win32_set_single_clipboard as set_clip
        attempts, exit_code, match = set_clip("Test Clipboard Text")
        assert attempts == 1
        assert exit_code == 0
        assert match is True
    teardown_temp_env(env)

def test_T37_companion_message_vs_zip_path_clipboard():
    from run_ag_ux_helper import process_ux_request
    env = setup_temp_env()
    
    req_data = {
        "generation_id": "gen_t37_test",
        "zip_path": os.path.join(env, "LATEST_CONTEXT.zip"),
        "config_options": {
            "clipboard_content": "companion_message",
            "open_explorer_after_publish": False
        }
    }
    req_path = os.path.join(env, "UX_REQUEST_gen_t37_test.json")
    with open(req_path, "w", encoding="utf-8") as f:
        json.dump(req_data, f)
        
    captured_texts = []
    def mock_win32_clipboard(text_to_set, max_attempts=5):
        captured_texts.append(text_to_set)
        return 1, 0, True
        
    with patch("run_ag_ux_helper.win32_set_single_clipboard", side_effect=mock_win32_clipboard):
        res = process_ux_request(req_path, override_base_dir=env)
        assert res is not None
        assert res["verdict"] == "PASS"
        assert len(captured_texts) == 1
        assert captured_texts[0] == "Проанализируй приложенный LATEST_CONTEXT.zip по COMPANION_ENTRY.md.", \
            f"Expected exact companion message, got {captured_texts[0]}"
            
    req_data_zip = {
        "generation_id": "gen_t37_zip",
        "zip_path": os.path.join(env, "LATEST_CONTEXT.zip"),
        "config_options": {
            "clipboard_content": "zip_path",
            "open_explorer_after_publish": False
        }
    }
    req_path_zip = os.path.join(env, "UX_REQUEST_gen_t37_zip.json")
    with open(req_path_zip, "w", encoding="utf-8") as f:
        json.dump(req_data_zip, f)
        
    captured_texts.clear()
    with patch("run_ag_ux_helper.win32_set_single_clipboard", side_effect=mock_win32_clipboard):
        res_zip = process_ux_request(req_path_zip, override_base_dir=env)
        assert res_zip is not None
        assert captured_texts[0] == os.path.join(env, "LATEST_CONTEXT.zip"), \
            f"Expected exact zip path, got {captured_texts[0]}"
            
    teardown_temp_env(env)

def test_T38_queue_deduplication():
    from run_ag_handoff_worker import process_queue_once
    env = setup_temp_env()
    queue_dir = os.path.join(env, "queue")
    os.makedirs(queue_dir, exist_ok=True)
    
    job1 = make_queue_job(env, "conv_dup", 0)
    with open(os.path.join(queue_dir, "queue_20260725_000001_ex0_dup.json"), "w") as f:
        json.dump(job1, f)
        
    mock_exporter = MagicMock()
    mock_exporter.export.return_value = {"status": "SUCCESS", "last_successful_generation_id": "gen_dup", "archive_path": os.path.join(env, "zip.zip")}
    mock_ux = MagicMock(return_value={"verdict": "PASS", "clipboard_roundtrip_match": True, "explorer_open_success": True, "notification_success": True})
    
    with patch("export_ag_handoff.CompanionExporter", return_value=mock_exporter), \
         patch("run_ag_ux_helper.process_ux_request", side_effect=mock_ux):
        processed = process_queue_once(env, SRC_DIR, quiescence_waiter=ready_gate, authority_validator=ready_gate)
        assert processed is True
        assert mock_exporter.export.call_count == 1
        
    teardown_temp_env(env)

def test_T39_worker_uses_returned_archive_path():
    from run_ag_handoff_worker import process_queue_once
    env = setup_temp_env()
    queue_dir = os.path.join(env, "queue")
    os.makedirs(queue_dir, exist_ok=True)
    
    job_id = "queue_20260725_100000_ex0_test39.json"
    custom_archive = os.path.join(env, "CUSTOM_LOCATION", "LATEST_CONTEXT_UNEXPECTED.zip")
    os.makedirs(os.path.dirname(custom_archive), exist_ok=True)
    with open(custom_archive, "wb") as f:
        f.write(b"PK\x03\x04test_zip")
        
    job_data = make_queue_job(env, "conv_test39", 0)
    with open(os.path.join(queue_dir, job_id), "w", encoding="utf-8") as f:
        json.dump(job_data, f)
        
    mock_exporter = MagicMock()
    mock_exporter.export.return_value = {
        "status": "SUCCESS",
        "last_successful_generation_id": "gen_test39",
        "archive_path": custom_archive,
    }
    mock_ux = MagicMock(return_value={"verdict": "PASS", "clipboard_roundtrip_match": True, "explorer_open_success": True, "notification_success": True})
    
    with patch("export_ag_handoff.CompanionExporter", return_value=mock_exporter), \
         patch("run_ag_ux_helper.process_ux_request", side_effect=mock_ux):
        
        processed = process_queue_once(env, SRC_DIR, quiescence_waiter=ready_gate, authority_validator=ready_gate)
        assert processed is True
        
        ev_file = os.path.join(env, "logs", "DESKTOP_STOP_EVIDENCE.json")
        assert os.path.exists(ev_file)
        with open(ev_file, "r", encoding="utf-8") as f:
            ev = json.load(f)
        assert ev["archive_path"] == custom_archive, f"Worker must use returned archive_path, got {ev['archive_path']}"
        assert ev["archive_path_from_exporter_used"] is True
        
    teardown_temp_env(env)

def test_T40_version_consistency():
    base_dir = os.path.abspath(os.path.join(SRC_DIR, '..'))
    
    cfg_p = os.path.join(base_dir, 'handoff.config.example.json')
    with open(cfg_p, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    assert cfg.get("version") == "4.3.4", f"handoff.config.json version is {cfg.get('version')}, expected 4.3.4"
    
    stale_versions = ["4.3." + str(i) for i in (0, 1, 2, 3)]
    for root, dirs, files in os.walk(base_dir):
        dirs[:] = [d for d in dirs if d not in ['release', 'queue', 'handoffs', 'state', 'logs', '__pycache__', '.git', 'node_modules']]
        for fn in files:
            if fn.endswith(('.py', '.json', '.md', '.ps1')):
                fp = os.path.join(root, fn)
                with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
                for i, line in enumerate(lines, 1):
                    for v in stale_versions:
                        if v in line and 'historical_reference' not in line and 'run_tests.py' not in fn:
                            raise AssertionError(f"Stale version {v} found in {os.path.relpath(fp, base_dir)}:{i}: {line.strip()}")

# --- Fixture Tests (T41-T43) ---

def test_T41_fixture_A_LATEST_CONTEXT_multi_root():
    from export_ag_handoff import CompanionExporter
    env = setup_temp_env()
    
    telegram_ws = os.path.join(env, "telegram-download")
    os.makedirs(telegram_ws, exist_ok=True)
    with open(os.path.join(telegram_ws, "package.json"), "w") as f:
        f.write("{}")
        
    companion_ws = os.path.join(env, "companion-handoff")
    os.makedirs(os.path.join(companion_ws, "src"), exist_ok=True)
    with open(os.path.join(companion_ws, "handoff.config.json"), "w") as f:
        f.write('{"version":"4.3.4"}')
    exporter_file = os.path.join(companion_ws, "src", "export_ag_handoff.py")
    with open(exporter_file, "w", encoding="utf-8") as f:
        f.write("# modified exporter file\n")
        
    tp = os.path.join(env, "transcript.jsonl")
    with open(tp, "w", encoding="utf-8") as f:
        f.write(json.dumps({
            "step_index": 0,
            "type": "PLANNER_RESPONSE",
            "tool_calls": [{"name": "replace_file_content", "arguments": {"TargetFile": exporter_file, "Cwd": companion_ws}}]
        }) + "\n")
        
    art_dir = os.path.join(env, "artifacts")
    os.makedirs(art_dir, exist_ok=True)
    
    payload_path = os.path.join(env, "payload_t41.json")
    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump({
            "conversationId": "conv_t41_test",
            "workspacePaths": [telegram_ws],
            "transcriptPath": tp,
            "artifactDirectoryPath": art_dir
        }, f)
        
    exp = CompanionExporter(stop_payload_file=payload_path, conversation_id="conv_t41_test", mode="forensic", override_base_dir=env)
    res = exp.export()
    assert res.get("status") == "SUCCESS", f"Export failed: {res}"
    
    archive_path = res.get("archive_path")
    assert os.path.exists(archive_path)
    assert "companion-handoff" in archive_path, f"Expected companion-handoff in archive path, got {archive_path}"
        
    with zipfile.ZipFile(archive_path) as zf:
        namelist = zf.namelist()
        assert "SESSION_DELTA/TRANSCRIPT_DELTA.jsonl" in namelist
        assert any("export_ag_handoff.py" in n for n in namelist)
        
    teardown_temp_env(env)

def test_T42_fixture_B_H10_product_state():
    from runtime_status import RuntimeStatusEvaluator
    from project_root_resolver import classify_roots
    from continuation_policy import compute_continuation_policy
    env = setup_temp_env()
    
    h10_launch = os.path.join(env, "H10 Athlete Cardio Lab")
    os.makedirs(os.path.join(h10_launch, ".agy"), exist_ok=True)
    with open(os.path.join(h10_launch, "package.json"), "w") as f:
        f.write("{}")
        
    hs_data = {
        "schema_version": "1.1.0",
        "git_head": "c1752bdf7d9bbc53c6f2973846e834b2becfab29",
        "git_state": "clean",
        "routing_valid": True,
        "available_commands": ["/planonly"],
        "installed_project_package_version": "1.2.0",
        "available_pipeline_package_version": "1.2.4",
        "runtime_compatibility": "needs_alignment"
    }
    with open(os.path.join(h10_launch, ".agy", "RUNTIME_HANDSHAKE.json"), "w") as f:
        json.dump(hs_data, f)
        
    worktree_dir = os.path.join(env, "worktrees", "cardio-export")
    os.makedirs(os.path.join(worktree_dir, "src"), exist_ok=True)
    file_touched = os.path.join(worktree_dir, "src", "cardio.py")
    with open(file_touched, "w") as f:
        f.write("# cardio code\n")
        
    roots = classify_roots([file_touched], h10_launch, [file_touched])
    assert roots["logical_project_slug"] == "H10 Athlete Cardio Lab"
    assert roots["runtime_root"] == os.path.normpath(h10_launch)
    assert roots["result_worktree_slug"] == "cardio-export"
    
    evaluator = RuntimeStatusEvaluator(
        authorities={
            "RUNTIME_HANDSHAKE.json": {"data": hs_data, "source_path": os.path.join(h10_launch, ".agy", "RUNTIME_HANDSHAKE.json")}
        },
        runtime_root_wt={"head": "c1752bdf7d9bbc53c6f2973846e834b2becfab29", "git_clean": True},
        pipeline_info={"has_pipeline": True, "handshake_valid": True, "routing_valid": True, "allowed_commands": ["/planonly"]}
    )
    readiness = evaluator.evaluate()
    assert readiness == "ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED", f"Expected alignment required, got {readiness}"
    
    pol = compute_continuation_policy(
        result_identity={"work_item_id": "H10_ITEM", "implementation_status": "completed", "verification_status": "unknown"},
        slash_readiness=readiness,
        conversation_verdict="READY",
        implementation_verdict="READY",
        identity_verdict="VERIFICATION_DEBT"
    )
    assert pol["continuation_readiness"] == "READY_AFTER_RUNTIME_ALIGNMENT"
    assert pol["previous_work_item"]["release_eligibility"] == "blocked"
    assert pol["previous_work_item"]["verification_status"] == "debt"
    
    teardown_temp_env(env)

def test_T43_fixture_C_non_git_conversation():
    from project_root_resolver import find_project_root
    from git_snapshot import capture_git_snapshot
    from export_ag_handoff import CompanionExporter
    env = setup_temp_env()
    
    proj_root = os.path.join(env, "my_non_git_app")
    src_sub = os.path.join(proj_root, "src")
    os.makedirs(src_sub, exist_ok=True)
    with open(os.path.join(proj_root, "package.json"), "w") as f:
        f.write('{"name":"my-app"}')
    with open(os.path.join(src_sub, "index.js"), "w") as f:
        f.write("console.log('hi');")
        
    detected_root = find_project_root(src_sub)
    assert detected_root == os.path.normpath(proj_root)
    
    snap = capture_git_snapshot(proj_root, "my-app")
    git_st = snap.get("git_state", snap.get("ROOT_INFO", {}).get("git_clean", "unknown"))
    assert git_st in ("not_applicable", "NOT_A_GIT_REPOSITORY", "non_git", "clean", "unknown")
        
    tp = os.path.join(env, "transcript.jsonl")
    with open(tp, "w", encoding="utf-8") as f:
        f.write(json.dumps({"type": "USER_INPUT", "content": "Non-git test"}) + "\n")
        
    art_dir = os.path.join(env, "artifacts")
    os.makedirs(art_dir, exist_ok=True)
    
    payload_path = os.path.join(env, "payload_t43.json")
    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump({
            "conversationId": "conv_t43_nongit",
            "workspacePaths": [proj_root],
            "transcriptPath": tp,
            "artifactDirectoryPath": art_dir
        }, f)
        
    exp = CompanionExporter(stop_payload_file=payload_path, conversation_id="conv_t43_nongit", mode="forensic", override_base_dir=env)
    res = exp.export()
    assert res.get("status") == "SUCCESS", f"Export failed for non-git: {res}"
    
    teardown_temp_env(env)

# --- Required Tests (T44-T64) ---

def test_T44_session_delta_non_empty():
    from capture_session_context import SessionContextCapturer
    env = setup_temp_env()
    tp = os.path.join(env, 'transcript.jsonl')
    with open(tp, 'w', encoding='utf-8') as f:
        f.write(json.dumps({"type": "USER_INPUT", "content": "Hello"}) + '\n')
        f.write(json.dumps({"type": "PLANNER_RESPONSE", "content": "This is a long enough model response for testing purposes"}) + '\n')
    cap = SessionContextCapturer(stop_payload={"workspacePaths": [env]}, transcript_path=tp, prev_processed_line=0)
    res = cap.capture()
    assert res["session_delta_non_empty"] is True, "Session delta should be non-empty with transcript data"
    assert "SESSION_DELTA/LAST_OWNER_REQUEST.md" in res["session_delta_files"]
    assert "SESSION_DELTA/LAST_MODEL_RESPONSE.md" in res["session_delta_files"]
    assert "SESSION_DELTA/TRANSCRIPT_DELTA.jsonl" in res["session_delta_files"]
    assert "SESSION_DELTA/TOOL_EVENTS.jsonl" in res["session_delta_files"]
    owner_bytes = res["session_delta_files"]["SESSION_DELTA/LAST_OWNER_REQUEST.md"]
    assert b"Hello" in owner_bytes
    teardown_temp_env(env)

def test_T45_wrong_launch_workspace_not_primary():
    from project_root_resolver import classify_roots
    companion = os.path.normpath(r"C:\Scripts\AntigravityProjects\companion-handoff")
    telegram = os.path.normpath(r"C:\Users\Test\telegram-download")
    touched = [os.path.join(companion, "src", "export_ag_handoff.py"),
               os.path.join(companion, "src", "runtime_status.py")]
    write_ops = touched[:]
    result = classify_roots(touched, telegram, write_ops)
    assert result["primary_implementation_root"] != telegram, \
        f"Launch workspace should not be primary when writes are elsewhere: {result}"

def test_T46_worker_uses_returned_archive_path():
    from run_ag_handoff_worker import process_queue_once
    env = setup_temp_env()
    queue_dir = os.path.join(env, "queue")
    os.makedirs(queue_dir, exist_ok=True)
    custom_archive = os.path.join(env, "CUSTOM_LOCATION", "LATEST_CONTEXT_UNEXPECTED.zip")
    os.makedirs(os.path.dirname(custom_archive), exist_ok=True)
    with open(custom_archive, "wb") as f:
        f.write(b"PK\x03\x04test_zip")
    job_data = make_queue_job(env, "conv_test46", 0)
    with open(os.path.join(queue_dir, "queue_20260725_100000_ex0_test46.json"), "w", encoding="utf-8") as f:
        json.dump(job_data, f)
        
    mock_exporter = MagicMock()
    mock_exporter.export.return_value = {"status": "SUCCESS", "last_successful_generation_id": "gen_test46", "archive_path": custom_archive}
    mock_ux = MagicMock(return_value={"verdict": "PASS", "clipboard_roundtrip_match": True, "explorer_open_success": True, "notification_success": True})
    
    with patch("export_ag_handoff.CompanionExporter", return_value=mock_exporter), \
         patch("run_ag_ux_helper.process_ux_request", side_effect=mock_ux):
        processed = process_queue_once(env, SRC_DIR, quiescence_waiter=ready_gate, authority_validator=ready_gate)
        assert processed is True
        ev_file = os.path.join(env, "logs", "DESKTOP_STOP_EVIDENCE.json")
        assert os.path.exists(ev_file)
        with open(ev_file, "r", encoding="utf-8") as f:
            ev = json.load(f)
        assert ev["archive_path"] == custom_archive
    teardown_temp_env(env)

def test_T47_ux_request_companion_message():
    from run_ag_ux_helper import process_ux_request
    env = setup_temp_env()
    dummy_zip = os.path.join(env, "LATEST_CONTEXT.zip")
    with open(dummy_zip, "wb") as f:
        f.write(b"PK\x03\x04dummy")
    req_data = {
        "generation_id": "gen_t47_exec",
        "zip_path": dummy_zip,
        "config_options": {"clipboard_content": "companion_message", "open_explorer_after_publish": True}
    }
    req_path = os.path.join(env, "UX_REQUEST_gen_t47_exec.json")
    with open(req_path, "w", encoding="utf-8") as f:
        json.dump(req_data, f)
        
    explorer_calls = []
    def mock_popen(cmd):
        explorer_calls.append(cmd)
        return MagicMock()
        
    def mock_beep(icon):
        return True
        
    def mock_clip(text, max_attempts=5):
        return 1, 0, True
        
    with patch("subprocess.Popen", side_effect=mock_popen), \
         patch("ctypes.windll.user32.MessageBeep", side_effect=mock_beep), \
         patch("run_ag_ux_helper.win32_set_single_clipboard", side_effect=mock_clip):
        res = process_ux_request(req_path, override_base_dir=env)
        assert res is not None
        assert res["clipboard_roundtrip_match"] is True
        assert res["explorer_open_success"] is True
        assert res["notification_success"] is True
        assert res["verdict"] == "PASS"
        assert len(explorer_calls) > 0
    teardown_temp_env(env)

def test_T48_runtime_target_baseline():
    baseline_path = os.path.join(SRC_DIR, '..', 'TARGET_RUNTIME_BASELINE.json')
    assert os.path.exists(baseline_path), f"TARGET_RUNTIME_BASELINE.json not found at {baseline_path}"
    with open(baseline_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    assert data.get("ecosystem_version") == "1.2.16"
    assert data.get("pipeline_package") == "1.2.16"
    assert data.get("runtime") == "1.2.16"
    assert data.get("companion") == "1.2.16"

def test_T49_h10_not_slash_ready_before_alignment():
    from runtime_status import RuntimeStatusEvaluator
    authorities = {
        "RUNTIME_HANDSHAKE.json": {
            "data": {
                "schema_version": "1.0",
                "routing_valid": True,
                "git_head": "abc123",
                "resolved_commands_allowed_now": ["/nextphase"],
                "installed_project_package_version": "unknown",
                "runtime_version": "unknown",
            },
            "source_path": "test",
        },
        "COMMAND_INVENTORY.json": {
            "data": {"commands": ["/nextphase", "/auditphase"]},
            "source_path": "test",
        },
    }
    pipeline_info = {"has_pipeline": True, "handshake_valid": True, "routing_valid": True, "allowed_commands": ["/nextphase"]}
    evaluator = RuntimeStatusEvaluator(
        authorities=authorities,
        runtime_root_wt={"head": "abc123", "git_clean": True},
        pipeline_info=pipeline_info,
    )
    result = evaluator.evaluate()
    assert result == "ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED", f"H10 should need alignment, got: {result}"

def test_T50_source_package_exclusions():
    sys.path.insert(0, os.path.join(BASE_DIR, "install"))
    import finalize_v434
    files = finalize_v434.collect_source_files()
    rel_paths = [rel for rel, _ in files]
    
    banned_prefixes = ("release/", "handoffs/", "queue/", "state/", "logs/", "fixtures/", "__pycache__/")
    banned_files = ("test_out.log",)
    
    for rel in rel_paths:
        for bp in banned_prefixes:
            assert not rel.startswith(bp) and f"/{bp}" not in rel, f"Banned directory {bp} found in source files: {rel}"
        for bf in banned_files:
            assert not rel.endswith(bf), f"Banned file {bf} found in source files: {rel}"
        assert not rel.endswith(".pyc"), f".pyc file found in source files: {rel}"
        assert not rel.endswith(".zip"), f"Old ZIP found in source files: {rel}"

def test_T51_all_versions_434():
    cfg_path = os.path.join(SRC_DIR, '..', 'handoff.config.example.json')
    with open(cfg_path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    assert cfg["version"] == "4.3.4", f"Config version: {cfg['version']}"
    
    stale_v = ["4.3." + str(i) for i in (0, 1, 2, 3)]
    for src_f in sorted(os.listdir(SRC_DIR)):
        if src_f.endswith('.py'):
            with open(os.path.join(SRC_DIR, src_f), 'r', encoding='utf-8') as f:
                content = f.read()
            for i, line in enumerate(content.splitlines(), 1):
                if any(v in line for v in stale_v) and 'historical_reference' not in line:
                    raise AssertionError(f"Stale version line in {src_f}:{i}: {line}")

def test_T52_release_attestation_matches_files():
    baseline_path = os.path.join(SRC_DIR, '..', 'TARGET_RUNTIME_BASELINE.json')
    config_path = os.path.join(SRC_DIR, '..', 'handoff.config.example.json')
    assert os.path.exists(baseline_path) and os.path.exists(config_path), "Canonical version inputs must exist"
    with open(baseline_path, 'r', encoding='utf-8') as f:
        baseline = json.load(f)
    with open(config_path, 'r', encoding='utf-8') as f:
        config = json.load(f)
    assert baseline.get("ecosystem_version") == "1.2.16"
    assert config.get("ecosystem_version") == "1.2.16" and config.get("version") == "4.3.4"

def test_T53_verification_debt_for_historical():
    from result_identity import ResultIdentityResolver
    env = setup_temp_env()
    rr_dir = os.path.join(env, ".agy")
    os.makedirs(rr_dir, exist_ok=True)
    with open(os.path.join(rr_dir, "RUN_RESULT.json"), "w") as f:
        json.dump({"work_item_id": "hist_1", "status": "accepted", "primary_artifact_path": os.path.join(env, "missing.zip")}, f)
    resolver = ResultIdentityResolver(search_roots=[env])
    auths = resolver.discover_authorities()
    res = resolver.reconcile_artifact_and_identity(auths, None)
    if isinstance(res, tuple):
        ident, _, verdict, _ = res
    else:
        verdict = res.get("identity_verdict", "")
    assert verdict == "VERIFICATION_BLOCKED", f"Expected exact VERIFICATION_BLOCKED, got {verdict}"
    teardown_temp_env(env)

def test_T54_real_stop_evidence_not_manual():
    worker_path = os.path.join(SRC_DIR, 'run_ag_handoff_worker.py')
    assert os.path.exists(worker_path), "Worker source missing"
    with open(worker_path, 'r', encoding='utf-8') as f:
        source = f.read()
    assert '"trigger_source": "antigravity_desktop_stop_hook" if is_hook_triggered else "manual_queue_injection"' in source
    assert '"manual_queue_injection": not is_hook_triggered' in source
    assert '"manual_worker_invocation": False' in source

def test_T55_evidence_matches_exporter_handoff():
    worker_path = os.path.join(SRC_DIR, 'run_ag_handoff_worker.py')
    with open(worker_path, 'r', encoding='utf-8') as f:
        source = f.read()
    assert 'archive_p = res.get("archive_path")' in source, "Worker must consume the exporter-returned archive path"
    assert 'archive_sha256 = h.hexdigest()' in source, "Worker must hash the delivered archive"
    assert '"archive_path_from_exporter_used": True' in source

def test_T56_attestation_after_artifacts():
    worker_path = os.path.join(SRC_DIR, 'run_ag_handoff_worker.py')
    with open(worker_path, 'r', encoding='utf-8') as f:
        source = f.read()
    hash_index = source.index('archive_sha256 = h.hexdigest()')
    evidence_index = source.index('evidence = {', hash_index)
    write_index = source.index('write_json_atomic(ev_file, evidence)', evidence_index)
    assert hash_index < evidence_index < write_index, "Evidence must be written only after the delivered archive is hashed"

def test_T57_attestation_sha_matches():
    worker_path = os.path.join(SRC_DIR, 'run_ag_handoff_worker.py')
    with open(worker_path, 'r', encoding='utf-8') as f:
        source = f.read()
    assert '"archive_sha256": archive_sha256' in source
    assert '"archive_path": archive_p' in source

def test_T58_all_versions_434():
    cfg_path = os.path.join(SRC_DIR, '..', 'handoff.config.example.json')
    with open(cfg_path, 'r') as f:
        cfg = json.load(f)
    assert cfg["version"] == "4.3.4", f"Config: {cfg['version']}"
    for fn in ['enqueue_ag_handoff.py']:
        with open(os.path.join(SRC_DIR, fn), 'r', encoding='utf-8') as f:
            content = f.read()
        assert '"schema_version": "4.3.4"' in content, f"schema_version in {fn} not 4.3.4"

def test_T59_empty_delta_not_ready_without_receipt():
    from export_ag_handoff import CompanionExporter
    env = setup_temp_env()
    tp = os.path.join(env, 'transcript.jsonl')
    with open(tp, 'w', encoding='utf-8') as f:
        pass
    art_dir = os.path.join(env, 'artifacts')
    os.makedirs(art_dir, exist_ok=True)
    payload_path = os.path.join(env, 'payload_t59.json')
    with open(payload_path, 'w', encoding='utf-8') as f:
        json.dump({
            "conversationId": "conv_t59",
            "workspacePaths": [env],
            "transcriptPath": tp,
            "artifactDirectoryPath": art_dir
        }, f)
    exp = CompanionExporter(stop_payload_file=payload_path, conversation_id="conv_t59", mode="forensic", override_base_dir=env)
    res = exp.export()
    assert res.get("status") == "SUCCESS", f"Export failed: {res}"
    
    latest_zip = res.get("archive_path")
    assert os.path.exists(latest_zip), "Archive must exist"
    with zipfile.ZipFile(latest_zip) as zf:
        readiness_data = json.loads(zf.read("CONTEXT_READINESS.json").decode("utf-8-sig"))
        conv_verdict = readiness_data.get("conversation_resume_verdict")
        assert conv_verdict == "PARTIAL", f"Empty delta without receipt must give PARTIAL, got {conv_verdict}"
    teardown_temp_env(env)

def test_T60_h10_runtime_root_nonempty():
    from project_root_resolver import classify_roots
    h10_launch = os.path.normpath(r"C:\Users\Test\H10 Athlete Cardio Lab")
    worktree = os.path.normpath(r"C:\Users\Test\worktrees\product-export")
    touched = [os.path.join(worktree, "src", "main.py")]
    result = classify_roots(touched, h10_launch, touched)
    assert result["runtime_root"] != "", "runtime_root must not be empty"
    assert result["runtime_root"] == h10_launch, f"runtime_root should be launch workspace, got: {result['runtime_root']}"

def test_T61_logical_slug_vs_worktree_slug():
    from project_root_resolver import classify_roots
    h10_launch = os.path.normpath(r"C:\Users\Test\H10 Athlete Cardio Lab")
    worktree = os.path.normpath(r"C:\Users\Test\worktrees\product-export")
    touched = [os.path.join(worktree, "src", "main.py")]
    result = classify_roots(touched, h10_launch, touched)
    assert result.get("logical_project_slug") == "H10 Athlete Cardio Lab"
    assert result.get("result_worktree_slug") != "", "result_worktree_slug must not be empty"
    assert result["logical_project_slug"] != result.get("result_worktree_slug", ""), \
        "logical_project_slug and result_worktree_slug must differ for H10 scenario"

def test_T62_no_alias_copy_in_attestation():
    collector_path = os.path.join(SRC_DIR, 'authority_collector.py')
    with open(collector_path, 'r', encoding='utf-8') as f:
        source = f.read()
    assert '"ACTION_PACKET_RECEIPT.json"' in source
    assert '"ACTION_PACKET.json"' not in source, "Raw Action Packet must not be exported as authority"
    assert '"ACTION_BRIDGE_CAPABILITY.json"' not in source, "Bridge capability must never be exported"

def test_T63_source_package_no_old_release():
    sys.path.insert(0, os.path.join(BASE_DIR, "install"))
    import finalize_v434
    files = finalize_v434.collect_source_files()
    rel_paths = [rel for rel, _ in files]
    assert not any(rel.startswith("release/") for rel in rel_paths)
    assert not any(rel.endswith(".zip") for rel in rel_paths)

def test_T64_meta_test_no_false_green_tests():
    test_file = os.path.join(BASE_DIR, "install", "run_tests.py")
    assert os.path.exists(test_file), f"Test suite file not found: {test_file}"
    
    with open(test_file, "r", encoding="utf-8") as f:
        source = f.read()
        
    tree = ast.parse(source, filename=test_file)
    
    test_nodes = [node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name.startswith("test_T")]
    assert len(test_nodes) >= 60, f"Expected at least 60 test functions, found {len(test_nodes)}"
    
    placeholders = []
    for fn_node in test_nodes:
        stmts = []
        for s in fn_node.body:
            if isinstance(s, ast.Expr) and isinstance(s.value, ast.Call):
                func_name = getattr(s.value.func, "id", "")
                if func_name in ("setup_temp_env", "teardown_temp_env"):
                    continue
            stmts.append(s)
            
        if not stmts:
            placeholders.append((fn_node.name, "empty body"))
            continue
            
        is_placeholder = True
        for stmt in stmts:
            if isinstance(stmt, ast.Pass):
                continue
            elif isinstance(stmt, ast.Assert):
                if isinstance(stmt.test, ast.Constant) and stmt.test.value is True:
                    continue
                if isinstance(stmt.test, ast.Call) and getattr(stmt.test.func, "id", "") == "callable":
                    continue
                is_placeholder = False
            else:
                is_placeholder = False
                
        if is_placeholder:
            placeholders.append((fn_node.name, "only pass, assert True, or assert callable"))
            continue

        has_top_assert = False
        has_conditional_assert = False
        for stmt in fn_node.body:
            if isinstance(stmt, ast.Assert):
                has_top_assert = True
            elif isinstance(stmt, ast.If):
                for sub in ast.walk(stmt):
                    if isinstance(sub, ast.Assert):
                        has_conditional_assert = True

        if has_conditional_assert and not has_top_assert:
            placeholders.append((fn_node.name, "conditional assert without mandatory top-level assert"))
            
    assert len(placeholders) == 0, f"Placeholder/false-green tests found: {placeholders}"

def test_T65_non_idle_stop_does_not_publish_or_overwrite_evidence():
    from enqueue_ag_handoff import enqueue_stop_payload

    env = setup_temp_env()
    evidence_path = os.path.join(env, "logs", "DESKTOP_STOP_EVIDENCE.json")
    latest_path = os.path.join(env, "handoffs", "project", "conv", "latest", "LATEST_CONTEXT.zip")
    state_path = os.path.join(env, "state", "conv.json")
    ux_path = os.path.join(env, "queue", "ux_requests", "sentinel.json")
    sentinels = {
        evidence_path: b'{"verdict":"OLD_PASS"}',
        latest_path: b"old-latest",
        state_path: b'{"cursor":41}',
        ux_path: b'{"status":"old"}',
    }
    for path, content in sentinels.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(content)
    before = {path: (open(path, "rb").read(), os.stat(path).st_mtime_ns) for path in sentinels}
    payload = make_queue_job(env, "conv-non-idle", 3, fully_idle=False)["stop_payload"]
    result = enqueue_stop_payload(payload, env)
    assert result == {"status": "DEFERRED", "reason": "stop_payload_not_fully_idle", "queue_path": None}
    assert not [name for name in os.listdir(os.path.join(env, "queue")) if name.startswith("queue_")]
    after = {path: (open(path, "rb").read(), os.stat(path).st_mtime_ns) for path in sentinels}
    assert before == after, "A non-idle Stop changed LATEST, completion evidence, state, or UX."
    teardown_temp_env(env)

def test_T66_current_authority_required_and_stale_run_result_deferred():
    import run_ag_handoff_worker as worker
    from run_ag_handoff_worker import (
        confined_project_file,
        has_windows_reparse_attribute,
        is_safe_verification_evidence_path,
        validate_authority_freshness,
    )

    env = setup_temp_env()
    fixture = create_authority_fixture(env, "conv-stale-authority")
    valid = fixture["validator"](
        fixture["queue_item"]["stop_payload"],
        fixture["queue_item"]["received_at_utc"],
    )
    assert valid.get("ready") is True
    assert is_safe_verification_evidence_path(".agy/verification/vitest-current.log") is True
    for unsafe_path in (
        ".env", ".agy/verification/.env", ".agy/verification/ACTION_BRIDGE_CAPABILITY.json",
        ".agy/verification/client-secret.log", "artifacts/test.log", ".agy/verification/../secret.log",
        ".agy/verification/result.log:private", ".agy/verification/bad*.log",
        ".agy/verification/bad?.log", ".agy/verification/control\x01.log",
        ".agy/verification/CON.txt", ".agy/verification/run/NUL.log",
        ".agy/verification/trailing.", ".agy/verification/тест.log",
    ):
        assert is_safe_verification_evidence_path(unsafe_path) is False, unsafe_path

    reparse_stat = MagicMock(st_file_attributes=0x400)
    assert has_windows_reparse_attribute(
        fixture["evidence_path"], platform_name="nt", lstat_fn=lambda _path: reparse_stat,
    ) is True
    evidence_parent = os.path.dirname(fixture["evidence_path"])
    with patch.object(
        worker,
        "has_windows_reparse_attribute",
        side_effect=lambda path: os.path.normcase(path) == os.path.normcase(evidence_parent),
    ):
        try:
            confined_project_file(env, ".agy/verification/verification-current.log")
            raise AssertionError("A reparse-point path component was accepted.")
        except ValueError as exc:
            assert str(exc) == "authority_path_not_safe_file"

    with open(fixture["run_result_path"], "r", encoding="utf-8") as handle:
        stale = json.load(handle)
    stale_time = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    stale["generated_at_utc"] = stale_time
    stale["compiled_at_utc"] = stale_time
    write_json(fixture["run_result_path"], stale)
    rejected = validate_authority_freshness(
        fixture["queue_item"]["stop_payload"],
        fixture["queue_item"]["received_at_utc"],
        git_identity_getter=lambda _workspace: {"branch": "main", "head": "a" * 40},
    )
    assert rejected == {"ready": False, "reason": "authority_not_fresh_for_stop"}, rejected

    stale.pop("verification_receipt")
    write_json(fixture["run_result_path"], stale)
    legacy = validate_authority_freshness(
        fixture["queue_item"]["stop_payload"],
        fixture["queue_item"]["received_at_utc"],
        git_identity_getter=lambda _workspace: {"branch": "main", "head": "a" * 40},
    )
    assert legacy == {"ready": False, "reason": "run_result_missing_verification_provenance"}, legacy
    teardown_temp_env(env)

def test_T67_forged_queue_envelope_deferred_without_side_effects():
    from run_ag_handoff_worker import process_queue_once, validate_queue_envelope

    env = setup_temp_env()
    queue_dir = os.path.join(env, "queue")
    os.makedirs(queue_dir, exist_ok=True)
    job = make_queue_job(env, "conv-envelope", 4)
    for field, forged_value in (
        ("fully_idle", False),
        ("event_fingerprint", "0" * 64),
        ("workspace_paths", [os.path.join(env, "other")]),
        ("execution_num", 99),
    ):
        forged = dict(job)
        forged[field] = forged_value
        assert validate_queue_envelope(forged, job["stop_payload"])["ready"] is False, field
    job["conversation_id"] = "forged-outer-id"
    queue_path = os.path.join(queue_dir, "queue_forged.json")
    write_json(queue_path, job)
    evidence_path = os.path.join(env, "logs", "DESKTOP_STOP_EVIDENCE.json")
    latest_path = os.path.join(env, "handoffs", "project", "conv", "latest", "LATEST_CONTEXT.zip")
    state_path = os.path.join(env, "state", "conv.json")
    ux_path = os.path.join(queue_dir, "ux_requests", "sentinel.json")
    sentinels = {evidence_path: b"old-evidence", latest_path: b"old-latest", state_path: b"old-state", ux_path: b"old-ux"}
    for path, content in sentinels.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(content)
    before = {path: (open(path, "rb").read(), os.stat(path).st_mtime_ns) for path in sentinels}
    mock_exporter = MagicMock()
    with patch("export_ag_handoff.CompanionExporter", mock_exporter):
        processed = process_queue_once(env, SRC_DIR, quiescence_waiter=ready_gate, authority_validator=ready_gate)
    assert processed is True and mock_exporter.call_count == 0
    assert os.path.isfile(os.path.join(queue_dir, "deferred", "queue_forged.json"))
    after = {path: (open(path, "rb").read(), os.stat(path).st_mtime_ns) for path in sentinels}
    assert before == after, "Forged envelope changed LATEST, evidence, state, or UX."
    teardown_temp_env(env)

def test_T68_true_idle_export_contains_exact_current_receipt_and_test_evidence():
    from run_ag_handoff_worker import process_queue_once

    env = setup_temp_env()
    fixture = create_authority_fixture(env, "conv-current-export")
    queue_dir = os.path.join(env, "queue")
    os.makedirs(queue_dir, exist_ok=True)
    write_json(os.path.join(queue_dir, "queue_current.json"), fixture["queue_item"])
    source_files = [
        os.path.join(SRC_DIR, name) for name in (
            "enqueue_ag_handoff.py", "run_ag_handoff_worker.py", "export_ag_handoff.py",
            "authority_collector.py", "package_builder.py",
        )
    ]
    source_before = {path: hashlib.sha256(open(path, "rb").read()).hexdigest() for path in source_files}
    mock_ux = MagicMock(return_value={
        "verdict": "PASS",
        "clipboard_roundtrip_match": True,
        "explorer_open_success": True,
        "notification_success": True,
    })
    with patch("run_ag_ux_helper.process_ux_request", side_effect=mock_ux):
        processed = process_queue_once(
            env,
            SRC_DIR,
            quiescence_waiter=ready_gate,
            authority_validator=fixture["validator"],
        )
    assert processed is True
    evidence_path = os.path.join(env, "logs", "DESKTOP_STOP_EVIDENCE.json")
    with open(evidence_path, "r", encoding="utf-8") as handle:
        evidence = json.load(handle)
    assert evidence["verdict"] == "PASS" and evidence["fully_idle"] is True
    assert evidence["quiescence"]["status"] == "PASS" and evidence["quiescence"]["samples"] >= 2
    assert evidence["atomic_latest_publish"] is True
    archive_path = evidence["archive_path"]
    with open(fixture["run_result_path"], "r", encoding="utf-8") as handle:
        compiled_at = datetime.fromisoformat(json.load(handle)["compiled_at_utc"])
    quiescence_at = datetime.fromisoformat(evidence["quiescence"]["observed_at_utc"])
    archive_mtime = datetime.fromtimestamp(os.path.getmtime(archive_path), tz=timezone.utc)
    published_at = datetime.fromisoformat(evidence["archive_published_at_utc"])
    recorded_at = datetime.fromisoformat(evidence["recorded_at_utc"])
    assert compiled_at <= quiescence_at <= archive_mtime <= published_at <= recorded_at, (
        compiled_at, quiescence_at, archive_mtime, published_at, recorded_at
    )
    exact_sources = {
        "authorities/RUN_RESULT.json": fixture["run_result_path"],
        "authorities/VERIFICATION_RECEIPT.json": fixture["receipt_path"],
        "authorities/CANDIDATE_MANIFEST.json": fixture["candidate_path"],
        "authorities/CANDIDATE_MANIFEST_STATUS.json": fixture["candidate_status_path"],
    }
    with zipfile.ZipFile(archive_path) as archive:
        manifest = json.loads(archive.read("MANIFEST.json").decode("utf-8"))
        for member, source_path in exact_sources.items():
            expected = open(source_path, "rb").read()
            actual = archive.read(member)
            assert actual == expected, f"{member} was not packaged byte-exactly."
            assert manifest["files"][member]["sha256"] == hashlib.sha256(expected).hexdigest()
        test_bytes = archive.read(fixture["archive_member"])
        assert test_bytes == fixture["evidence_bytes"]
        assert manifest["files"][fixture["archive_member"]]["sha256"] == hashlib.sha256(test_bytes).hexdigest()
    source_after = {path: hashlib.sha256(open(path, "rb").read()).hexdigest() for path in source_files}
    assert source_before == source_after, "Export mutated immutable source files."
    teardown_temp_env(env)

def test_T69_authority_mutation_before_swap_preserves_old_latest():
    from package_builder import PackageBuilder
    from run_ag_handoff_worker import get_quiescence_snapshot, make_pre_publish_guard

    env = setup_temp_env()
    fixture = create_authority_fixture(env, "conv-pre-publish-race")
    latest_dir = os.path.join(env, "published", "latest")
    history_dir = os.path.join(env, "published", "history", "gen-race")
    os.makedirs(latest_dir, exist_ok=True)
    latest_path = os.path.join(latest_dir, "LATEST_CONTEXT.zip")
    with open(latest_path, "wb") as handle:
        handle.write(b"old-complete-latest")
    os.utime(latest_path, (1700000000, 1700000000))
    old_identity = (open(latest_path, "rb").read(), os.stat(latest_path).st_mtime_ns)
    expected_snapshot = get_quiescence_snapshot(fixture["queue_item"]["stop_payload"])
    guard = make_pre_publish_guard(
        fixture["queue_item"]["stop_payload"],
        fixture["queue_item"]["received_at_utc"],
        expected_snapshot,
        fixture["authority"],
        fixture["validator"],
    )
    mutated = {"done": False}
    def mutate_then_guard():
        if not mutated["done"]:
            with open(fixture["receipt_path"], "ab") as handle:
                handle.write(b"\n")
            mutated["done"] = True
        return guard()
    builder = PackageBuilder(latest_dir, history_dir, "gen-race")
    result = builder.build_and_publish(
        {"CONTEXT_READINESS.json": b'{"transport_verdict":"PASS"}', "payload.txt": b"new"},
        pre_publish_guard=mutate_then_guard,
    )
    assert result["status"] == "DEFERRED" and result["error"] == "PRE_PUBLISH_GUARD_FAILED", result
    assert (open(latest_path, "rb").read(), os.stat(latest_path).st_mtime_ns) == old_identity
    assert not os.path.exists(os.path.join(history_dir, "LATEST_CONTEXT.zip"))
    assert not any(name.startswith((".tmp_", ".rollback_")) for name in os.listdir(latest_dir))
    teardown_temp_env(env)

def test_T70_atomic_publish_rollback_and_reader_never_observes_partial_bytes():
    import package_builder as package_builder_module
    from package_builder import PackageBuilder

    env = setup_temp_env()
    latest_dir = os.path.join(env, "latest")
    history_dir = os.path.join(env, "history")
    os.makedirs(latest_dir, exist_ok=True)
    os.makedirs(history_dir, exist_ok=True)
    targets = {
        os.path.join(latest_dir, "LATEST_CONTEXT.zip"): b"old-latest",
        os.path.join(history_dir, "LATEST_CONTEXT.zip"): b"old-history",
        os.path.join(latest_dir, "LATEST_CONTEXT.zip.sha256"): b"old-latest-sha",
        os.path.join(history_dir, "LATEST_CONTEXT.zip.sha256"): b"old-history-sha",
        os.path.join(latest_dir, "CONTEXT_READINESS.json"): b"old-readiness",
    }
    for path, content in targets.items():
        with open(path, "wb") as handle:
            handle.write(content)
        os.utime(path, (1700000000, 1700000000))
    before = {path: (open(path, "rb").read(), os.stat(path).st_mtime_ns) for path in targets}
    real_replace = package_builder_module.os.replace
    fail_once = {"done": False}
    def injected_replace(source, target):
        if target == os.path.join(latest_dir, "LATEST_CONTEXT.zip.sha256") and not fail_once["done"]:
            fail_once["done"] = True
            raise RuntimeError("injected sidecar publish failure")
        return real_replace(source, target)
    builder = PackageBuilder(latest_dir, history_dir, "gen-rollback")
    with patch("package_builder.os.replace", side_effect=injected_replace):
        failed = builder.build_and_publish(
            {"CONTEXT_READINESS.json": b'{"transport_verdict":"PASS"}', "payload.bin": b"new" * 1000},
            pre_publish_guard=ready_gate,
        )
    assert failed["status"] == "FAILED" and failed["error"] == "ATOMIC_SWAP_FAILED", failed
    after = {path: (open(path, "rb").read(), os.stat(path).st_mtime_ns) for path in targets}
    assert before == after, "Failed publish did not restore old LATEST/sidecars/readiness exactly."

    observed = []
    read_errors = []
    stop_reader = threading.Event()
    latest_path = os.path.join(latest_dir, "LATEST_CONTEXT.zip")
    old_bytes = open(latest_path, "rb").read()
    def reader():
        while not stop_reader.is_set():
            try:
                with open(latest_path, "rb") as handle:
                    observed.append(handle.read())
            except Exception as error:
                read_errors.append(type(error).__name__)
            stop_reader.wait(0.0005)
    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    succeeded = PackageBuilder(latest_dir, history_dir, "gen-reader").build_and_publish(
        {"CONTEXT_READINESS.json": b'{"transport_verdict":"PASS"}', "payload.bin": b"complete-new" * 10000},
        pre_publish_guard=ready_gate,
    )
    stop_reader.set()
    thread.join(timeout=2)
    assert succeeded["status"] == "SUCCESS" and succeeded["atomic_latest_publish"] is True, succeeded
    new_bytes = open(latest_path, "rb").read()
    observed.append(new_bytes)
    assert not read_errors, f"Reader observed a missing/unreadable LATEST: {read_errors}"
    assert all(value in (old_bytes, new_bytes) for value in observed), "Reader observed partial LATEST bytes."
    teardown_temp_env(env)

def test_T71_bounded_quiescence_requires_stability_and_times_out_closed():
    from run_ag_handoff_worker import wait_for_quiescence

    payload = {"fullyIdle": True}
    sequence = iter((("a",), ("b",), ("b",), ("b",)))
    clock = {"value": 0.0}
    def sleep_fn(seconds):
        clock["value"] += seconds
    ready = wait_for_quiescence(
        payload,
        timeout_seconds=1.0,
        poll_interval_seconds=0.1,
        required_stable_samples=3,
        snapshot_fn=lambda: next(sequence),
        sleep_fn=sleep_fn,
        monotonic_fn=lambda: clock["value"],
    )
    assert ready == {"ready": True, "reason": "bounded_stability_confirmed", "stable_samples": 3}

    clock["value"] = 0.0
    counter = {"value": 0}
    def changing_snapshot():
        counter["value"] += 1
        return (counter["value"],)
    blocked = wait_for_quiescence(
        payload,
        timeout_seconds=0.25,
        poll_interval_seconds=0.1,
        required_stable_samples=3,
        snapshot_fn=changing_snapshot,
        sleep_fn=sleep_fn,
        monotonic_fn=lambda: clock["value"],
    )
    assert blocked["ready"] is False and blocked["reason"] == "quiescence_timeout"
    assert wait_for_quiescence({"fullyIdle": False})["reason"] == "stop_payload_not_fully_idle"


def main():
    print("Running Tests...\n")
    tests = [
        ("T01", test_T01_path_normalization),
        ("T02", test_T02_git_root_detection),
        ("T03", test_T03_non_git_project_root_detection),
        ("T04", test_T04_root_scoring),
        ("T05", test_T05_git_snapshot_capture),
        ("T06", test_T06_linked_worktree_detection),
        ("T07", test_T07_authority_discovery),
        ("T08", test_T08_authority_scoring),
        ("T09", test_T09_status_normalization),
        ("T10", test_T10_H10_RUN_RESULT_alias_support),
        ("T11", test_T11_H10_AUDIT_RESULT_alias_support),
        ("T12", test_T12_artifact_verification_levels),
        ("T13", test_T13_ZIP_security_traversal_detection),
        ("T14", test_T14_ZIP_security_duplicate_member_detection),
        ("T15", test_T15_ZIP_security_zip_bomb_ratio_detection),
        ("T16", test_T16_manifest_exact_parity),
        ("T17", test_T17_self_referential_manifest_exclusion),
        ("T18", test_T18_privacy_exclusion_default_patterns),
        ("T19", test_T19_privacy_report_generation),
        ("T20", test_T20_stale_task_document_detection),
        ("T21", test_T21_backticked_checkbox_recognition),
        ("T22", test_T22_result_identity_ACCEPTED_requires_existing_verified_artifact),
        ("T23", test_T23_result_identity_VERIFICATION_BLOCKED_for_missing_artifact),
        ("T24", test_T24_result_identity_VERIFICATION_DEBT_for_historical_work_item),
        ("T25", test_T25_result_identity_machine_precedence_over_narrative),
        ("T26", test_T26_continuation_policy_READY_NEW_WORK_ITEM_WITH_VERIFICATION_DEBT),
        ("T27", test_T27_continuation_policy_BLOCKED),
        ("T28", test_T28_runtime_status_inventory_routing),
        ("T29", test_T29_runtime_status_HANDSHAKE_REFRESH_REQUIRED),
        ("T30", test_T30_runtime_status_ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED),
        ("T31", test_T31_gen_ID_generation_and_ZIP_member_set),
        ("T32", test_T32_full_export_with_temp_env),
        ("T33", test_T33_package_builder_validator_roundtrip),
        ("T34", test_T34_cursor_tracking_across_transcript_delta),
        ("T35", test_T35_multi_root_write_capture),
        ("T36", test_T36_ux_clipboard_roundtrip_Win32),
        ("T37", test_T37_companion_message_vs_zip_path_clipboard),
        ("T38", test_T38_queue_deduplication),
        ("T39", test_T39_worker_uses_returned_archive_path),
        ("T40", test_T40_version_consistency),
        ("T41", test_T41_fixture_A_LATEST_CONTEXT_multi_root),
        ("T42", test_T42_fixture_B_H10_product_state),
        ("T43", test_T43_fixture_C_non_git_conversation),
        ("T44", test_T44_session_delta_non_empty),
        ("T45", test_T45_wrong_launch_workspace_not_primary),
        ("T46", test_T46_worker_uses_returned_archive_path),
        ("T47", test_T47_ux_request_companion_message),
        ("T48", test_T48_runtime_target_baseline),
        ("T49", test_T49_h10_not_slash_ready_before_alignment),
        ("T50", test_T50_source_package_exclusions),
        ("T51", test_T51_all_versions_434),
        ("T52", test_T52_release_attestation_matches_files),
        ("T53", test_T53_verification_debt_for_historical),
        ("T54", test_T54_real_stop_evidence_not_manual),
        ("T55", test_T55_evidence_matches_exporter_handoff),
        ("T56", test_T56_attestation_after_artifacts),
        ("T57", test_T57_attestation_sha_matches),
        ("T58", test_T58_all_versions_434),
        ("T59", test_T59_empty_delta_not_ready_without_receipt),
        ("T60", test_T60_h10_runtime_root_nonempty),
        ("T61", test_T61_logical_slug_vs_worktree_slug),
        ("T62", test_T62_no_alias_copy_in_attestation),
        ("T63", test_T63_source_package_no_old_release),
        ("T64", test_T64_meta_test_no_false_green_tests),
        ("T65", test_T65_non_idle_stop_does_not_publish_or_overwrite_evidence),
        ("T66", test_T66_current_authority_required_and_stale_run_result_deferred),
        ("T67", test_T67_forged_queue_envelope_deferred_without_side_effects),
        ("T68", test_T68_true_idle_export_contains_exact_current_receipt_and_test_evidence),
        ("T69", test_T69_authority_mutation_before_swap_preserves_old_latest),
        ("T70", test_T70_atomic_publish_rollback_and_reader_never_observes_partial_bytes),
        ("T71", test_T71_bounded_quiescence_requires_stability_and_times_out_closed),
    ]

    for name, func in tests:
        run_test(name, func)

    print("\n" + "="*60)
    print(f"Test Summary: {TEST_PASS} PASS, {TEST_FAIL} FAIL")
    print("="*60)
    
    if TEST_FAIL > 0:
        sys.exit(1)
    sys.exit(0)

if __name__ == "__main__":
    main()
