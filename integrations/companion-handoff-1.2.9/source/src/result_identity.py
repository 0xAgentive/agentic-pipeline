#!/usr/bin/env python3
"""
result_identity.py - Result Identity Reconciliation module for Auto Context Handoff v4.3.4.

Discovers machine authorities across worktrees, resolves relative artifact paths,
verifies primary artifacts (CRC, member set, internal manifest, hashes),
and evaluates result identity verdict (ACCEPTED, RECONCILIATION_REQUIRED, VERIFICATION_BLOCKED).
"""

import os
import json
import glob
import re
import zipfile
import hashlib

def safe_read_json(filepath):
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None

def get_file_sha256(filepath_or_bytes):
    try:
        h = hashlib.sha256()
        if isinstance(filepath_or_bytes, bytes):
            h.update(filepath_or_bytes)
        elif isinstance(filepath_or_bytes, str) and os.path.exists(filepath_or_bytes):
            with open(filepath_or_bytes, "rb") as f:
                while chunk := f.read(65536):
                    h.update(chunk)
        else:
            h.update(str(filepath_or_bytes).encode("utf-8"))
        return h.hexdigest()
    except Exception:
        return None

AUTHORITY_FILES = [
    "RUN_RESULT.json",
    "AUDIT_RESULT.json",
    "PHASE_RESULT.json",
    "RUNTIME_HANDSHAKE.json",
    "PHASE_STATUS.json",
    "INSTALLATION_MANIFEST.json",
    "COMMAND_INVENTORY.json",
]

class ResultIdentityResolver:
    def __init__(self, search_roots, artifact_dir=None):
        self.search_roots = [os.path.normpath(r) for r in search_roots if r and os.path.exists(r)]
        self.artifact_dir = artifact_dir

    def discover_authorities_for_dir(self, directory):
        found = {}
        subdirs = [
            directory,
            os.path.join(directory, ".agy"),
            os.path.join(directory, ".agents"),
            os.path.join(directory, ".artifacts"),
            os.path.join(directory, "artifacts"),
            os.path.join(directory, "reports"),
            os.path.join(directory, "validation"),
        ]
        for sd in subdirs:
            if not os.path.isdir(sd):
                continue
            for af_name in AUTHORITY_FILES:
                if af_name in found:
                    continue
                af_path = os.path.join(sd, af_name)
                if os.path.isfile(af_path):
                    data = safe_read_json(af_path)
                    if data is not None:
                        found[af_name] = {
                            "source_path": af_path,
                            "data": data,
                            "size_bytes": os.path.getsize(af_path),
                            "sha256": get_file_sha256(af_path),
                        }
        return found

    def discover_authorities(self):
        found = {}
        for root in self.search_roots:
            root_auth = self.discover_authorities_for_dir(root)
            for k, v in root_auth.items():
                if k not in found:
                    found[k] = v

        if self.artifact_dir and os.path.isdir(self.artifact_dir):
            art_auth = self.discover_authorities_for_dir(self.artifact_dir)
            for k, v in art_auth.items():
                if k not in found:
                    found[k] = v
        return found

    def resolve_result_worktree(self, worktrees_info, primary_impl_root, authorities):
        """Resolve the product worktree for result identity binding.
        Uses primary_implementation_root first, then RUN_RESULT/AUDIT_RESULT hints."""
        if not worktrees_info:
            return None, "no_worktrees"

        # Step 1: Match primary implementation root
        if primary_impl_root:
            norm_impl = os.path.normpath(primary_impl_root)
            for wt in worktrees_info:
                if os.path.normpath(wt.get("path", "")) == norm_impl:
                    return wt, "primary_implementation_root_match"

        # Step 2: Explicit worktree in RUN_RESULT
        run_res = authorities.get("RUN_RESULT.json", {}).get("data", {})
        wt_path = run_res.get("worktree") or run_res.get("project_root")
        if wt_path:
            norm_wt = os.path.normpath(wt_path)
            for wt in worktrees_info:
                if os.path.normpath(wt.get("path", "")) == norm_wt:
                    return wt, "run_result_explicit_worktree"

        # Step 3: Branch/HEAD match RUN_RESULT
        r_branch = run_res.get("branch")
        r_head = run_res.get("head") or run_res.get("git_head")
        if r_branch or r_head:
            for wt in worktrees_info:
                b_match = r_branch and (wt.get("branch", "").endswith(r_branch) or wt.get("branch_name") == r_branch)
                h_match = r_head and wt.get("head", "").startswith(r_head[:12])
                if b_match and h_match:
                    return wt, "run_result_branch_head_match"

        # Step 4: AUDIT_RESULT worktree
        audit_res = authorities.get("AUDIT_RESULT.json", {}).get("data", {})
        a_wt = audit_res.get("worktree") or audit_res.get("project_root")
        if a_wt:
            norm_a = os.path.normpath(a_wt)
            for wt in worktrees_info:
                if os.path.normpath(wt.get("path", "")) == norm_a:
                    return wt, "audit_result_worktree_match"

        # Step 5: Single worktree
        if len(worktrees_info) == 1:
            return worktrees_info[0], "single_worktree"

        return None, "no_result_worktree_match"

    def resolve_runtime_root(self, worktrees_info, authorities, launch_workspace):
        """Resolve the runtime root for slash readiness evaluation.
        Uses RUNTIME_HANDSHAKE project_root, then launch workspace."""
        if not worktrees_info:
            return None, "no_worktrees"

        handshake = authorities.get("RUNTIME_HANDSHAKE.json", {}).get("data", {})
        hs_root = handshake.get("project_root") or handshake.get("workspace_root")
        if hs_root:
            norm_hs = os.path.normpath(hs_root)
            for wt in worktrees_info:
                if os.path.normpath(wt.get("path", "")) == norm_hs:
                    return wt, "runtime_handshake_root"

        if launch_workspace:
            norm_lw = os.path.normpath(launch_workspace)
            for wt in worktrees_info:
                if os.path.normpath(wt.get("path", "")) == norm_lw:
                    return wt, "launch_workspace"

        if len(worktrees_info) == 1:
            return worktrees_info[0], "single_worktree"

        return None, "no_runtime_root_match"

    def resolve_artifact_path(self, raw_path, run_result_source_path, selected_wt):
        """
        Resolves relative artifact path relative to:
        1. RUN_RESULT directory
        2. Selected worktree
        3. Search roots
        """
        if not raw_path:
            return None
        if os.path.isabs(raw_path) and os.path.exists(raw_path):
            return os.path.normpath(raw_path)

        candidates = []
        if run_result_source_path:
            run_dir = os.path.dirname(run_result_source_path)
            candidates.append(os.path.join(run_dir, raw_path))

        wt_path = selected_wt.get("path") if selected_wt else None
        if wt_path:
            candidates.append(os.path.join(wt_path, raw_path))
            candidates.append(os.path.join(wt_path, ".agy", raw_path))

        for root in self.search_roots:
            candidates.append(os.path.join(root, raw_path))

        if self.artifact_dir:
            candidates.append(os.path.join(self.artifact_dir, raw_path))

        for cand in candidates:
            norm_c = os.path.normpath(cand)
            if os.path.exists(norm_c):
                return norm_c

        # Fallback to absolute normalization even if not yet created
        return os.path.normpath(raw_path)

    def verify_primary_artifact(self, artifact_path):
        """
        Thorough primary artifact verification:
        - Open ZIP
        - CRC check (testzip)
        - Exact member set vs internal MANIFEST.json when present
        - Size and SHA-256 verification of members when internal manifest exists
        """
        if not artifact_path or not os.path.isfile(artifact_path):
            return {
                "exists": False,
                "verified": False,
                "crc_passed": False,
                "manifest_present": False,
                "manifest_valid": False,
                "member_count": 0,
            }

        fsize = os.path.getsize(artifact_path)
        sha = get_file_sha256(artifact_path)

        if not artifact_path.lower().endswith(".zip"):
            return {
                "exists": True,
                "verified": True,
                "crc_passed": True,
                "manifest_present": False,
                "manifest_valid": False,
                "size_bytes": fsize,
                "sha256": sha,
            }

        crc_passed = False
        manifest_present = False
        manifest_valid = False
        member_count = 0

        try:
            with zipfile.ZipFile(artifact_path, "r") as zf:
                bad_file = zf.testzip()
                crc_passed = (bad_file is None)

                namelist = zf.namelist()
                member_count = len(namelist)

                if "MANIFEST.json" in namelist:
                    manifest_present = True
                    manifest_bytes = zf.read("MANIFEST.json")
                    mdata = json.loads(manifest_bytes.decode("utf-8-sig"))

                    # Verify members listed in internal manifest
                    files_dict = mdata.get("files", {})
                    all_matched = True
                    for fname, meta in files_dict.items():
                        if fname not in namelist:
                            all_matched = False
                            break
                        data_b = zf.read(fname)
                        if meta.get("size") is not None and len(data_b) != meta["size"]:
                            all_matched = False
                            break
                        if meta.get("sha256") and get_file_sha256(data_b) != meta["sha256"]:
                            all_matched = False
                            break

                    manifest_valid = all_matched
                else:
                    # Non-manifest zip is verified if CRC passed and not empty
                    manifest_valid = crc_passed and member_count > 0
        except Exception:
            crc_passed = False
            manifest_valid = False

        verified = crc_passed and (not manifest_present or manifest_valid)

        return {
            "exists": True,
            "verified": verified,
            "crc_passed": crc_passed,
            "manifest_present": manifest_present,
            "manifest_valid": manifest_valid,
            "size_bytes": fsize,
            "sha256": sha,
            "member_count": member_count,
        }

    def reconcile_artifact_and_identity(self, authorities, selected_wt, narrative_text="", pipeline_info=None):
        has_pipeline = (pipeline_info or {}).get("has_pipeline", False)
        run_info = authorities.get("RUN_RESULT.json", {})
        audit_info = authorities.get("AUDIT_RESULT.json", {})

        run_res = run_info.get("data")
        audit_res = audit_info.get("data")
        phase_status = authorities.get("PHASE_STATUS.json", {}).get("data")

        run_source_path = run_info.get("source_path")
        audit_source_path = audit_info.get("source_path")

        work_item_id = None
        work_item_status = "unknown"

        if run_res:
            work_item_id = run_res.get("work_item") or run_res.get("work_item_id") or run_res.get("task_id")
            work_item_status = (
                run_res.get("acceptance_status") or
                run_res.get("verification_status") or
                run_res.get("work_item_status") or
                run_res.get("status") or
                "unknown"
            )
        elif audit_res:
            work_item_id = audit_res.get("target_work_item") or audit_res.get("work_item") or audit_res.get("work_item_id")
            work_item_status = audit_res.get("audit_status") or "unknown"
        elif phase_status:
            work_item_id = phase_status.get("current_phase")
            work_item_status = phase_status.get("current_status") or phase_status.get("status") or "unknown"

        wt_path = selected_wt.get("path", "") if selected_wt else ""
        wt_branch = (selected_wt.get("branch_name") or selected_wt.get("branch", "")) if selected_wt else ""
        wt_head = selected_wt.get("head", "") if selected_wt else ""

        # Resolve primary artifact candidates with machine-result precedence:
        # RUN_RESULT → AUDIT_RESULT → PHASE_RESULT → artifact registry → worktree files → transcript hints
        machine_candidates = []
        discovery_candidates = []

        # Source 1: RUN_RESULT (highest precedence)
        if run_res:
            p = run_res.get("export_artifact") or run_res.get("primary_artifact_path") or run_res.get("artifact_path")
            if p:
                machine_candidates.append((p, run_source_path))

        # Source 2: AUDIT_RESULT
        if audit_res:
            p = audit_res.get("artifact_path") or audit_res.get("export_artifact") or audit_res.get("primary_artifact_path")
            if p:
                machine_candidates.append((p, audit_source_path))

        # Source 3: PHASE_RESULT / artifact registry
        phase_result = authorities.get("PHASE_RESULT.json", {}).get("data", {})
        if phase_result:
            p = phase_result.get("artifact_path") or phase_result.get("export_artifact") or phase_result.get("primary_artifact_path")
            if p:
                machine_candidates.append((p, authorities.get("PHASE_RESULT.json", {}).get("source_path")))

        # Resolve machine candidates first
        candidate_paths = []
        for rp, sp in machine_candidates:
            resolved = self.resolve_artifact_path(rp, sp, selected_wt)
            if resolved and resolved not in candidate_paths:
                candidate_paths.append(resolved)

        # Discovery hints only apply when no machine result specified any artifact path.
        # If a machine result specifies a path that doesn't exist, that's PRIMARY_ARTIFACT_MISSING,
        # not an invitation to search for other ZIPs.
        machine_specified_path = len(machine_candidates) > 0

        if not machine_specified_path:
            # Source 4: Verified files under artifact_dir
            if self.artifact_dir and os.path.isdir(self.artifact_dir):
                for z in glob.glob(os.path.join(self.artifact_dir, "*.zip")):
                    discovery_candidates.append((z, None))

            # Source 5: Absolute .zip paths in SESSION_DELTA / LAST_MODEL_RESPONSE (hints only)
            if narrative_text:
                zip_paths = re.findall(r'[A-Za-z]:\\[^\s"\'<>|*?]+\.zip', narrative_text)
                zip_paths += re.findall(r'/[^\s"\'<>|*?]+\.zip', narrative_text)
                for zp in zip_paths:
                    discovery_candidates.append((zp, None))

            # Source 6: COMMAND_TRACE.json .zip paths
            for sr in self.search_roots:
                ct_path = os.path.join(sr, ".agy", "COMMAND_TRACE.json")
                if os.path.isfile(ct_path):
                    ct_data = safe_read_json(ct_path)
                    if isinstance(ct_data, dict):
                        for entry in ct_data.get("traces", ct_data.get("commands", [])):
                            if isinstance(entry, dict):
                                for k in ["output_path", "artifact_path", "result_path"]:
                                    v = entry.get(k, "")
                                    if isinstance(v, str) and v.lower().endswith(".zip"):
                                        discovery_candidates.append((v, ct_path))

            # Source 7: TOUCHED_FILES.json created/viewed ZIP paths
            for sr in self.search_roots:
                tf_path = os.path.join(sr, ".agy", "TOUCHED_FILES.json")
                if os.path.isfile(tf_path):
                    tf_data = safe_read_json(tf_path)
                    if isinstance(tf_data, dict):
                        for flist in [tf_data.get("created", []), tf_data.get("viewed", []), tf_data.get("modified", [])]:
                            if isinstance(flist, list):
                                for fp in flist:
                                    if isinstance(fp, str) and fp.lower().endswith(".zip"):
                                        discovery_candidates.append((fp, tf_path))

            # Source 8: product_recovery directory under selected worktree
            if wt_path:
                recovery_dir = os.path.join(wt_path, ".artifacts", "product_recovery")
                if os.path.isdir(recovery_dir):
                    for root_d, _, files in os.walk(recovery_dir):
                        for fn in files:
                            if fn.lower().endswith(".zip"):
                                discovery_candidates.append((os.path.join(root_d, fn), None))

            for rp, sp in discovery_candidates:
                resolved = self.resolve_artifact_path(rp, sp, selected_wt)
                if resolved and resolved not in candidate_paths:
                    candidate_paths.append(resolved)

        narrative_name_mismatch = False
        if narrative_text and candidate_paths:
            mach_name = os.path.basename(candidate_paths[0])
            z_matches = re.findall(r"\b([a-zA-Z0-9_\-]+\.zip)\b", narrative_text, re.IGNORECASE)
            if z_matches:
                for zm in z_matches:
                    if zm.lower() != mach_name.lower():
                        narrative_name_mismatch = True

        artifact_entries = []
        valid_candidates = []

        for cp in candidate_paths:
            ver_info = self.verify_primary_artifact(cp)
            entry = {
                "artifact_id": os.path.basename(cp),
                "role": "primary_product_artifact",
                "work_item_id": work_item_id,
                "worktree": wt_path,
                "branch": wt_branch,
                "head": wt_head,
                "absolute_path": cp,
                "exists": ver_info["exists"],
                "size_bytes": ver_info.get("size_bytes", 0),
                "sha256": ver_info.get("sha256"),
                "crc_passed": ver_info["crc_passed"],
                "manifest_present": ver_info["manifest_present"],
                "manifest_valid": ver_info["manifest_valid"],
                "verified": ver_info["verified"],
            }
            artifact_entries.append(entry)
            if ver_info["verified"]:
                valid_candidates.append(entry)

        reason_codes = []
        identity_verdict = "NO_CURRENT_RESULT"
        if narrative_name_mismatch:
            reason_codes.append("NON_BLOCKING_NARRATIVE_NAME_MISMATCH")

        if not has_pipeline and not run_res:
            identity_verdict = "NOT_APPLICABLE"
        elif not run_res:
            if phase_status and phase_status.get("current_status") in ["completed", "accepted", "awaiting_audit"]:
                reason_codes.append("MISSING_RUN_RESULT_FOR_COMPLETED_WORK_ITEM")
                identity_verdict = "VERIFICATION_BLOCKED"
            else:
                identity_verdict = "NO_CURRENT_RESULT"
        else:
            run_included = "RUN_RESULT.json" in authorities
            run_head = run_res.get("head") or run_res.get("git_head")
            run_work_item = run_res.get("work_item") or run_res.get("work_item_id") or run_res.get("task_id")
            run_status_clean = work_item_status.lower() in ["accepted", "passed", "success"]

            r_head_match = True if not (run_head and wt_head) else wt_head.startswith(run_head[:12])
            r_item_match = True if not (run_work_item and work_item_id) else (run_work_item == work_item_id)

            if not run_included:
                reason_codes.append("RUN_RESULT_NOT_IN_ZIP")
                identity_verdict = "VERIFICATION_BLOCKED"
            elif not run_status_clean:
                reason_codes.append(f"RUN_RESULT_STATUS_{work_item_status.upper()}")
                identity_verdict = "VERIFICATION_BLOCKED"
            elif not r_head_match:
                reason_codes.append("RUN_RESULT_HEAD_MISMATCH")
                identity_verdict = "VERIFICATION_BLOCKED"
            elif not r_item_match:
                reason_codes.append("RUN_RESULT_WORK_ITEM_MISMATCH")
                identity_verdict = "VERIFICATION_BLOCKED"
            elif len(valid_candidates) == 0:
                if any(e.get("exists") for e in artifact_entries):
                    reason_codes.append("UNVERIFIED_PRIMARY_ARTIFACT")
                else:
                    reason_codes.append("PRIMARY_ARTIFACT_MISSING")
                    
                    is_historical = False
                    if phase_status:
                        curr_phase = phase_status.get("current_phase") or phase_status.get("current_work_item")
                        if curr_phase and work_item_id and str(curr_phase) != str(work_item_id):
                            is_historical = True
                            
                    assurance_mode = (run_res.get("assurance_mode") or "").upper()
                    
                    if is_historical and run_status_clean and assurance_mode in ["GUARDED", "RELEASE"]:
                        identity_verdict = "VERIFICATION_DEBT"
                    elif is_historical and run_status_clean and assurance_mode not in ["STRICT", "BLOCKING"]:
                        identity_verdict = "VERIFICATION_DEBT"
                    else:
                        identity_verdict = "VERIFICATION_BLOCKED"
            elif len(valid_candidates) > 1:
                reason_codes.append("AMBIGUOUS_PRIMARY_ARTIFACT")
                identity_verdict = "RESULT_IDENTITY_RECONCILIATION_REQUIRED"
            else:
                # Exactly 1 valid, verified candidate

                audit_req = run_res.get("audit_required", False) or run_res.get("requires_audit", False) or (work_item_status.lower() in ["guarded", "release"])
                audit_included = "AUDIT_RESULT.json" in authorities

                if audit_req and not audit_included:
                    reason_codes.append("MISSING_REQUIRED_AUDIT")
                    identity_verdict = "VERIFICATION_BLOCKED"
                elif audit_included and audit_res:
                    a_head = audit_res.get("head") or audit_res.get("git_head")
                    a_item = audit_res.get("target_work_item") or audit_res.get("work_item") or audit_res.get("work_item_id")
                    a_status = (audit_res.get("audit_status") or audit_res.get("status") or "").lower()

                    a_head_match = True if not (a_head and wt_head) else wt_head.startswith(a_head[:12])
                    a_item_match = True if not (a_item and work_item_id) else (a_item == work_item_id)
                    a_status_clean = a_status in ["passed", "accepted", "success"]

                    if not a_status_clean:
                        reason_codes.append(f"AUDIT_STATUS_{a_status.upper()}")
                        identity_verdict = "VERIFICATION_BLOCKED"
                    elif not a_head_match:
                        reason_codes.append("AUDIT_HEAD_MISMATCH")
                        identity_verdict = "VERIFICATION_BLOCKED"
                    elif not a_item_match:
                        reason_codes.append("AUDIT_WORK_ITEM_MISMATCH")
                        identity_verdict = "VERIFICATION_BLOCKED"
                    else:
                        identity_verdict = "ACCEPTED"
                else:
                    identity_verdict = "ACCEPTED"

        result_identity_data = {
            "work_item_id": work_item_id,
            "work_item_status": work_item_status,
            "selected_worktree": wt_path,
            "branch": wt_branch,
            "head": wt_head,
            "identity_verdict": identity_verdict,
            "primary_artifact": valid_candidates[0] if valid_candidates else None,
            "candidate_count": len(artifact_entries),
            "reason_codes": reason_codes,
        }

        return result_identity_data, artifact_entries, identity_verdict, reason_codes
