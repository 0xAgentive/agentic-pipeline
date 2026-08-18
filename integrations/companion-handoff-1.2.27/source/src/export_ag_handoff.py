#!/usr/bin/env python3
"""
export_ag_handoff.py - Antigravity Companion Handoff Exporter v4.3.4
                       Auto Context Handoff — Production Closure

Orchestrates context capture, artifact resolution, diagnostics, 
and package building for v4.3.4.
"""

import sys
import os
import json
import time
import shutil
import hashlib
from datetime import datetime, timezone

SRC_DIR = os.path.dirname(os.path.abspath(__file__))
if SRC_DIR not in sys.path:
    sys.path.insert(0, SRC_DIR)

from capture_session_context import SessionContextCapturer
from result_identity import ResultIdentityResolver
from runtime_status import RuntimeStatusEvaluator
from package_validator import PackageValidator
from project_root_resolver import classify_roots
from git_snapshot import get_zip_entries
from authority_collector import collect_and_select
from continuation_policy import compute_continuation_policy
from diagnostics import DiagnosticsCollector
from package_builder import PackageBuilder


def safe_read_json(filepath):
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None

def json_bytes(data):
    return json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8-sig")

class CompanionExporter:
    def __init__(
        self,
        stop_payload_file=None,
        conversation_id=None,
        mode="handoff",
        override_base_dir=None,
        required_authority=None,
        pre_publish_guard=None,
    ):
        self.base_dir = override_base_dir or os.environ.get("COMPANION_HANDOFF_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        self.logs_dir = os.path.join(self.base_dir, "logs")
        self.mode = mode
        self.required_authority = required_authority
        self.pre_publish_guard = pre_publish_guard
        
        self.diag = DiagnosticsCollector()
        self.diag.start_timer("total_export")

        os.makedirs(self.logs_dir, exist_ok=True)

        self.config = self.load_config()
        self.conversation_id = conversation_id
        self.stop_payload = None
        self.queue_item = {}

        if stop_payload_file and os.path.exists(stop_payload_file):
            try:
                with open(stop_payload_file, "r", encoding="utf-8-sig") as f:
                    data = json.load(f)
                    self.queue_item = data
                    self.stop_payload = data.get("stop_payload", data)
                    if not self.conversation_id:
                        self.conversation_id = self.stop_payload.get("conversationId") or data.get("conversation_id")
            except Exception as e:
                self.diag.error("init", "INPUT_CONTEXT_INVALID", f"Failed to read payload file: {e}")

        if not self.conversation_id:
            raise ValueError("Conversation ID is required.")

        self.artifact_dir = None
        self.transcript_file = None

        if self.stop_payload:
            self.artifact_dir = self.stop_payload.get("artifactDirectoryPath")
            self.transcript_file = self.stop_payload.get("transcriptPath")

        if self.mode in ["forensic-recent", "forensic-full"] and (not self.artifact_dir or not self.transcript_file):
            brain_base = os.environ.get("GEMINI_BRAIN_DIR") or os.path.join(os.path.expanduser("~"), ".gemini", "antigravity", "brain")
            self.artifact_dir = os.path.join(brain_base, self.conversation_id)
            self.transcript_file = os.path.join(self.artifact_dir, ".system_generated", "logs", "transcript.jsonl")
            if not os.path.exists(self.transcript_file) or self.mode == "forensic-full":
                self.transcript_file = os.path.join(self.artifact_dir, ".system_generated", "logs", "transcript_full.jsonl")

        self.state_file = os.path.join(self.base_dir, "state", f"{self.conversation_id}.json")
        self.prev_state = self.load_state()

    def load_config(self):
        cfg_p = os.path.join(self.base_dir, "handoff.config.json")
        if os.path.exists(cfg_p):
            with open(cfg_p, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        return {"clipboard_content": "zip_path", "open_explorer_after_publish": False, "select_zip_in_explorer": False, "version": "4.3.4"}

    def load_state(self):
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file, "r", encoding="utf-8-sig") as f:
                    return json.load(f)
            except Exception:
                pass
        return {}

    def save_state(self, state_data):
        os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
        tmp = self.state_file + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state_data, f, ensure_ascii=False, indent=2)
        shutil.move(tmp, self.state_file)

    def generate_gen_id(self, last_gen_id):
        idx = 0
        if last_gen_id and last_gen_id.startswith("gen_ex"):
            parts = last_gen_id.split("_")
            if len(parts) >= 2:
                try:
                    idx = int(parts[1].replace("ex", "")) + 1
                except Exception:
                    idx = 0
        import hashlib
        rnd = hashlib.sha256(f"{time.time()}_{self.conversation_id}".encode("utf-8")).hexdigest()[:8]
        return f"gen_ex{idx}_{rnd}"

    def export(self):
        now_utc = datetime.now(timezone.utc).isoformat()
        last_gen_id = self.prev_state.get("last_successful_generation_id")
        gen_id = self.generate_gen_id(last_gen_id)
        
        self.diag.info("export", "Starting export", {"gen_id": gen_id, "mode": self.mode})

        prev_processed_line = self.prev_state.get("last_processed_transcript_line", 0)
        if self.mode == "forensic-full":
            prev_processed_line = 0

        # c. Capture session context
        self.diag.start_timer("capture_session")
        capturer = SessionContextCapturer(
            stop_payload=self.stop_payload,
            transcript_path=self.transcript_file,
            privacy_config=self.config.get("privacy", {}),
            prev_processed_line=prev_processed_line,
        )
        cap_res = capturer.capture()
        self.diag.stop_timer("capture_session")

        touched_files_data = cap_res["touched_files"]
        touched_paths = [info["path"] for info in touched_files_data.get("files", [])]
        write_operations = [info["path"] for info in touched_files_data.get("files", []) if info["operation"] in ["created", "edited", "deleted"]]
        
        ws_paths = [p for p in (self.stop_payload or {}).get("workspacePaths", []) if p]
        launch_ws = ws_paths[0] if ws_paths else ""

        # d. Resolve project roots using project_root_resolver
        root_classes = classify_roots(touched_paths, launch_ws, write_operations)
        primary_impl_root = root_classes["primary_implementation_root"]
        
        impl_roots = []
        if primary_impl_root:
            impl_roots.append(primary_impl_root)
        if root_classes["additional_implementation_roots"]:
            impl_roots.extend(root_classes["additional_implementation_roots"].split(","))

        import os
        # Use logical project slug from root resolver for publish path
        # If launch_ws has no writes and primary_impl_root is different, use primary_impl_root slug
        launch_ws_has_writes = any(w.lower().startswith(launch_ws.lower()) for w in write_operations) if launch_ws else False
        if primary_impl_root and launch_ws and not launch_ws_has_writes and os.path.normpath(primary_impl_root) != os.path.normpath(launch_ws):
            proj_slug = os.path.basename(os.path.normpath(primary_impl_root))
        else:
            proj_slug = root_classes.get("logical_project_slug") or os.path.basename(os.path.normpath(launch_ws or "companion-handoff"))
        if not proj_slug or proj_slug == ".":
            proj_slug = "companion-handoff"

        root_classes["logical_project_slug"] = proj_slug

        publish_dir = os.path.join(self.base_dir, "handoffs", proj_slug, self.conversation_id)
        latest_dir = os.path.join(publish_dir, "latest")
        history_dir = os.path.join(publish_dir, "history", gen_id)

        # e. Capture git snapshots for each root
        git_entries = {}
        for root in impl_roots:
            import hashlib
            root_id = hashlib.sha256(root.encode("utf-8")).hexdigest()[:8]
            entries = get_zip_entries(root, root_id)
            git_entries.update(entries)

        # f. Collect authorities
        search_roots = list(set([launch_ws] + impl_roots))
        if self.artifact_dir:
            search_roots.append(self.artifact_dir)
            
        authorities_data = collect_and_select(search_roots, self.artifact_dir)
        if self.required_authority:
            required_files = {
                "RUN_RESULT.json": (
                    self.required_authority.get("run_result_path"),
                    self.required_authority.get("run_result_sha256"),
                ),
                "VERIFICATION_RECEIPT.json": (
                    self.required_authority.get("receipt_path"),
                    self.required_authority.get("receipt_sha256"),
                ),
                "CANDIDATE_MANIFEST.json": (
                    self.required_authority.get("candidate_manifest_path"),
                    self.required_authority.get("candidate_manifest_sha256"),
                ),
                "CANDIDATE_MANIFEST_STATUS.json": (
                    self.required_authority.get("candidate_status_path"),
                    self.required_authority.get("candidate_status_sha256"),
                ),
            }
            captured_authority_bytes = {}
            for authority_name, (authority_path, expected_sha256) in required_files.items():
                if not authority_path or not os.path.isfile(authority_path):
                    return {"status": "DEFERRED", "error": "REQUIRED_AUTHORITY_MISSING"}
                with open(authority_path, "rb") as authority_file:
                    authority_bytes = authority_file.read()
                if hashlib.sha256(authority_bytes).hexdigest() != expected_sha256:
                    return {"status": "DEFERRED", "error": "REQUIRED_AUTHORITY_CHANGED"}
                captured_authority_bytes[authority_name] = authority_bytes
                authority_data = safe_read_json(authority_path)
                if not isinstance(authority_data, dict):
                    return {"status": "DEFERRED", "error": "REQUIRED_AUTHORITY_INVALID"}
                authorities_data[authority_name] = {
                    "path": authority_path,
                    "data": authority_data,
                    "selection_reason": "Exact worker-validated authority binding",
                    "score": 100,
                }
            captured_test_evidence = {}
            for evidence in self.required_authority.get("test_evidence", []):
                evidence_path = evidence.get("path")
                archive_member = evidence.get("archive_member")
                expected_sha256 = evidence.get("sha256")
                expected_size = evidence.get("size_bytes")
                if not evidence_path or not archive_member or not os.path.isfile(evidence_path):
                    return {"status": "DEFERRED", "error": "REQUIRED_TEST_EVIDENCE_MISSING"}
                with open(evidence_path, "rb") as evidence_file:
                    evidence_bytes = evidence_file.read()
                if len(evidence_bytes) != expected_size or hashlib.sha256(evidence_bytes).hexdigest() != expected_sha256:
                    return {"status": "DEFERRED", "error": "REQUIRED_TEST_EVIDENCE_CHANGED"}
                if archive_member in captured_test_evidence:
                    return {"status": "DEFERRED", "error": "REQUIRED_TEST_EVIDENCE_DUPLICATE"}
                captured_test_evidence[archive_member] = evidence_bytes
        
        # Format for ResultIdentityResolver
        authorities_for_resolver = {}
        for k, v in authorities_data.items():
            authorities_for_resolver[k] = {
                "data": v["data"],
                "source_path": v["path"]
            }

        # g. Resolve result identity
        worktrees_info = [{"path": r, "branch": "", "head": ""} for r in impl_roots]
        resolver = ResultIdentityResolver(search_roots=search_roots, artifact_dir=self.artifact_dir)
        selected_wt, _ = resolver.resolve_result_worktree(worktrees_info, primary_impl_root, authorities_for_resolver)
        
        pipeline_info = {"has_pipeline": "RUNTIME_HANDSHAKE.json" in authorities_for_resolver}
        if pipeline_info["has_pipeline"]:
            hs = authorities_for_resolver["RUNTIME_HANDSHAKE.json"]["data"]
            pipeline_info["handshake_valid"] = hs.get("schema_valid", True)
            pipeline_info["routing_valid"] = hs.get("routing_valid", True)
            pipeline_info["allowed_commands"] = hs.get("resolved_commands_allowed_now", [])
            pipeline_info["requires_one_time_alignment"] = False
            
        res_id_data, artifact_entries, identity_verdict, res_id_reasons = resolver.reconcile_artifact_and_identity(
            authorities=authorities_for_resolver,
            selected_wt=selected_wt,
            narrative_text=cap_res["session_delta"].get("last_model_response", ""),
            pipeline_info=pipeline_info,
        )

        # h. Evaluate runtime status
        runtime_root_wt, _ = resolver.resolve_runtime_root(worktrees_info, authorities_for_resolver, launch_ws)
        evaluator = RuntimeStatusEvaluator(
            authorities=authorities_for_resolver, 
            runtime_root_wt=runtime_root_wt or {}, 
            pipeline_info=pipeline_info, 
            handoff_config=self.config
        )
        slash_readiness = evaluator.evaluate()

        # Implementation / Conversation verdicts
        stale_documents = cap_res.get("stale_documents", False)
        uncaptured_ext_root = cap_res.get("uncaptured_external_write_root", False)
        conversation_resume_verdict = "PARTIAL" if (stale_documents or uncaptured_ext_root) else "READY"
        
        session_delta_non_empty = cap_res.get("session_delta_non_empty", True)
        if not session_delta_non_empty:
            # All session delta files are empty markers
            conversation_resume_verdict = "PARTIAL"
        implementation_resume_verdict = "BLOCKED" if (stale_documents or uncaptured_ext_root) else ("READY" if impl_roots else "NOT_APPLICABLE")

        # i. Compute continuation policy
        cont_policy = compute_continuation_policy(
            result_identity=res_id_data,
            slash_readiness=slash_readiness,
            conversation_verdict=conversation_resume_verdict,
            implementation_verdict=implementation_resume_verdict,
            identity_verdict=identity_verdict,
            work_item_info=res_id_data,
        )

        # Build files
        file_contents = {}

        # j. Build TASK_COHERENCE.json
        file_contents["TASK_COHERENCE.json"] = json_bytes({
            "stale_documents": stale_documents,
            "uncaptured_external_write_root": uncaptured_ext_root,
            "missing_truncated_snapshots": cap_res.get("missing_truncated_snapshots", [])
        })

        # k. Build PRIVACY_REPORT.json
        file_contents["PRIVACY_REPORT.json"] = json_bytes({
            "exclusion_count": len(cap_res.get("privacy_exclusions", [])),
            "excluded_files": cap_res.get("privacy_exclusions", [])
        })
        
        # l. Build RUNTIME_TARGET.json
        rt = authorities_for_resolver.get("TARGET_RUNTIME_BASELINE.json", {}).get("data", {})
        file_contents["RUNTIME_TARGET.json"] = json_bytes({
            "ecosystem_version": rt.get("ecosystem_version", "1.2.27"),
            "target_pipeline_package": rt.get("pipeline_package", "1.2.27"),
            "target_runtime": rt.get("runtime", "1.2.27"),
            "target_companion": rt.get("companion", "1.2.27"),
            "runtime_environment": rt.get("runtime_environment", "Antigravity Desktop"),
            "os_requirements": rt.get("os_requirements", {"os": "Windows 11", "shell": "PowerShell 7.6+", "python": "3.11+"}),
        })

        # m. Build RUNTIME_STATUS.json
        file_contents["RUNTIME_STATUS.json"] = json_bytes({
            "slash_readiness": slash_readiness,
            "pipeline_info": pipeline_info,
            "status_details": "Extracted by RuntimeStatusEvaluator"
        })

        # n. Build CONTINUATION_POLICY.json
        file_contents["CONTINUATION_POLICY.json"] = json_bytes(cont_policy)
        
        continuation_readiness = cont_policy.get("continuation_readiness", "BLOCKED")
        release_eligibility = cont_policy.get("previous_work_item", {}).get("release_eligibility", "blocked")

        # o. Build COMPANION_ENTRY.md
        entry_md = f"""# Companion Entry — Auto Context Handoff v4.3.4

Ответь ровно пятью блоками:

1. **Контекст разговора** — состояние: `{conversation_resume_verdict}`.
2. **Контекст реализации** — состояние: `{implementation_resume_verdict}`.
3. **Предыдущий work item** — identity: `{identity_verdict}`, release: `{release_eligibility}`.
4. **Runtime и slash readiness** — статус: `{slash_readiness}`.
5. **Следующее действие владельца** — `{continuation_readiness}`.

Generation ID: `{gen_id}`
Project Slug: `{proj_slug}`
Primary Implementation Root: `{primary_impl_root}`
"""
        if cont_policy.get("previous_work_item", {}).get("verification_status") == "debt":
            entry_md += """
Предыдущая реализация сохранена как verification debt.
Её выпуск закрыт.
Новая разработка разрешится после выравнивания runtime.
"""
        file_contents["COMPANION_ENTRY.md"] = entry_md.encode("utf-8")

        # p. Build CONTEXT_READINESS.json
        readiness_payload = {
            "generation_id": gen_id,
            "created_at_utc": now_utc,
            "transport_verdict": "PASS",
            "conversation_resume_verdict": conversation_resume_verdict,
            "implementation_resume_verdict": implementation_resume_verdict,
            "result_identity_verdict": identity_verdict,
            "slash_readiness": slash_readiness,
            "continuation_readiness": continuation_readiness
        }
        file_contents["CONTEXT_READINESS.json"] = json_bytes(readiness_payload)

        file_contents["CURRENT_AUTHORITY.json"] = json_bytes(root_classes)
        file_contents["TOUCHED_FILES.json"] = json_bytes(touched_files_data)
        # Add session delta files as directory entries
        for sd_key, sd_bytes in cap_res.get("session_delta_files", {}).items():
            file_contents[sd_key] = sd_bytes
        
        file_contents.update(git_entries)
        for snap_key, snap_bytes in cap_res.get("source_snapshots", {}).items():
            file_contents[snap_key] = snap_bytes
            
        for af_name, af_info in authorities_for_resolver.items():
            if self.required_authority and af_name in captured_authority_bytes:
                file_contents[f"authorities/{af_name}"] = captured_authority_bytes[af_name]
            else:
                file_contents[f"authorities/{af_name}"] = json_bytes(af_info["data"])
        if self.required_authority:
            file_contents.update(captured_test_evidence)

        # Diagnostics dump
        self.diag.stop_timer("total_export")
        file_contents["DIAGNOSTICS.json"] = self.diag.to_json_bytes()

        # q. PackageBuilder
        builder = PackageBuilder(latest_dir, history_dir, gen_id, self.diag)
        build_res = builder.build_and_publish(
            file_contents,
            PackageValidator,
            pre_publish_guard=self.pre_publish_guard,
        )

        if build_res["status"] == "DEFERRED":
            return {"status": "DEFERRED", "error": build_res["error"], "details": build_res.get("details")}
        if build_res["status"] != "SUCCESS":
            return {"status": "FAILED", "error": build_res["error"], "details": build_res.get("details")}

        # r. UX Request
        if self.config.get("clipboard_content") == "companion_message":
            ux_msg = "Проанализируй приложенный LATEST_CONTEXT.zip по COMPANION_ENTRY.md."
            with open(os.path.join(latest_dir, "COMPANION_MESSAGE.txt"), "w", encoding="utf-8") as f:
                f.write(ux_msg)

        new_state = {
            "last_successful_generation_id": gen_id,
            "last_processed_transcript_line": cap_res.get("current_line_idx", prev_processed_line),
            "updated_at_utc": now_utc,
            "proj_slug": proj_slug,
        }
        self.save_state(new_state)

        # s. Return dict
        return {
            "status": "SUCCESS",
            "last_successful_generation_id": gen_id,
            "archive_path": build_res["archive_path"],
            "archive_sha256": build_res.get("archive_sha256"),
            "published_at_utc": build_res.get("published_at_utc"),
            "atomic_latest_publish": build_res.get("atomic_latest_publish") is True,
            "quiescence_checked_at_utc": build_res.get("quiescence_checked_at_utc"),
            "transport_verdict": "PASS",
            "conversation_resume_verdict": conversation_resume_verdict,
            "implementation_resume_verdict": implementation_resume_verdict,
            "result_identity_verdict": identity_verdict,
            "slash_readiness": slash_readiness,
            "continuation_readiness": continuation_readiness
        }

if __name__ == "__main__":
    if len(sys.argv) > 1:
        payload_f = sys.argv[1]
        mode = "handoff"
        try:
            with open(payload_f, "r", encoding="utf-8-sig") as f:
                _pd = json.load(f)
            _sp = _pd.get("stop_payload", _pd)
            if not _sp.get("artifactDirectoryPath") and not _sp.get("transcriptPath"):
                mode = "forensic-recent"
        except Exception:
            mode = "forensic-recent"
        exp = CompanionExporter(stop_payload_file=payload_f, mode=mode)
        res = exp.export()
        print(json.dumps(res, indent=2))
