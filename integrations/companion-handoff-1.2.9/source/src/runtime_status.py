#!/usr/bin/env python3
"""
runtime_status.py - Runtime & Slash Readiness module for Auto Context Handoff v4.3.4.

Evaluates installed versions, handshake freshness, distinguishes HANDSHAKE_REFRESH_REQUIRED
from ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED, and checks slash command readiness.

SLASH_READY_FOR_NEW_GOAL requires inventory-based routing:
  1. current runtime identity is compatible
  2. handshake is schema-valid and fresh
  3. runtime-root HEAD and Git state match the handshake
  4. routing is valid
  5. resolved_commands_allowed_now contains at least one command present in COMMAND_INVENTORY
  6. routing is not a terminal no-command state
"""

import os
import json

def safe_read_json(filepath):
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None

class RuntimeStatusEvaluator:
    def __init__(self, authorities=None, runtime_root_wt=None, pipeline_info=None, handoff_config=None):
        self.authorities = authorities or {}
        self.runtime_root_wt = runtime_root_wt or {}
        self.pipeline_info = pipeline_info or {}
        self.handoff_config = handoff_config or {}

    def evaluate(self):
        has_pipeline = self.pipeline_info.get("has_pipeline", False)

        if not has_pipeline:
            return "NOT_APPLICABLE"

        im = self.authorities.get("INSTALLATION_MANIFEST.json", {}).get("data", {})
        hs = self.authorities.get("RUNTIME_HANDSHAKE.json", {}).get("data", {})
        ci = self.authorities.get("COMMAND_INVENTORY.json", {}).get("data", {})

        installed_pkg = im.get("package_version") or hs.get("installed_project_package_version") or "unknown"
        installed_rt = im.get("runtime_version") or hs.get("runtime_version") or "unknown"

        handshake_present = bool(hs) or bool(self.pipeline_info.get("handshake_valid"))
        schema_valid = bool(hs.get("schema_version")) if hs else self.pipeline_info.get("handshake_valid", False)
        routing_valid = hs.get("routing_valid", False) if hs else self.pipeline_info.get("routing_valid", False)

        wt_head = self.runtime_root_wt.get("head", "")
        hs_head = hs.get("git_head", "") if hs else ""

        head_match = True
        if hs_head and wt_head:
            head_match = wt_head.startswith(hs_head[:12]) or hs_head.startswith(wt_head[:12])

        # Compare real git cleanliness against handshake claim
        git_clean = self.runtime_root_wt.get("git_clean", True)
        hs_git_state = hs.get("git_state", "") if hs else ""
        git_state_match = True
        if hs_git_state == "clean":
            git_state_match = git_clean
        elif hs_git_state == "dirty":
            git_state_match = not git_clean

        stale = hs.get("stale_state", False) if hs else False
        routing_errors = hs.get("routing_errors", []) if hs else []

        fresh = (
            handshake_present
            and schema_valid
            and head_match
            and git_state_match
            and not stale
            and len(routing_errors) == 0
        )

        # historical_reference: Inventory-based routing check (Fix 3 of v4.3.0)
        # No hardcoded /new-goal. Instead: resolved_commands_allowed_now must contain
        # at least one command present in project-local COMMAND_INVENTORY.json
        resolved_allowed = hs.get("resolved_commands_allowed_now", []) if hs else self.pipeline_info.get("allowed_commands", [])

        # Build inventory command set from COMMAND_INVENTORY.json
        inventory_commands = set()
        if isinstance(ci, dict):
            # COMMAND_INVENTORY may have commands as keys or as a list
            for key in ["commands", "available_commands", "registered_commands"]:
                cmds = ci.get(key, [])
                if isinstance(cmds, list):
                    for c in cmds:
                        if isinstance(c, str):
                            inventory_commands.add(c)
                        elif isinstance(c, dict):
                            cn = c.get("name") or c.get("command") or c.get("id")
                            if cn:
                                inventory_commands.add(cn)
                elif isinstance(cmds, dict):
                    inventory_commands.update(cmds.keys())
            # Also accept top-level keys that look like command names
            for k in ci:
                if k.startswith("/"):
                    inventory_commands.add(k)

        # resolved_allowed commands that are also in inventory
        inventory_routable = bool(resolved_allowed) and (
            # If we have an inventory, at least one resolved command must be in it
            (bool(inventory_commands) and any(c in inventory_commands for c in resolved_allowed))
            # If no inventory file exists, accept any non-empty resolved set
            or (not inventory_commands and not ci)
        )

        # Terminal no-command state: resolved list is empty or null
        terminal_state = (not resolved_allowed) or (len(resolved_allowed) == 0)

        compat = hs.get("runtime_compatibility", "compatible") if hs else "compatible"
        avail_pkg = hs.get("available_pipeline_package_version", "") if hs else ""

        version_mismatch = (compat != "compatible") or bool(avail_pkg and installed_pkg != "unknown" and avail_pkg != installed_pkg)
        requires_one_time_alignment = self.pipeline_info.get("requires_one_time_alignment", False) or version_mismatch

        tb_auth = self.authorities.get("TARGET_RUNTIME_BASELINE.json", {})
        tb = tb_auth.get("data", {}) if isinstance(tb_auth, dict) else {}
        tb_exists = bool(tb_auth)
        
        if tb_exists:
            target_pkg = tb.get("pipeline_package")
            if target_pkg and installed_pkg != target_pkg:
                requires_one_time_alignment = True
            
            target_rt = tb.get("runtime")
            if target_rt and installed_rt != target_rt:
                requires_one_time_alignment = True
        elif bool(hs):
            requires_one_time_alignment = True

        if not handshake_present:
            slash_readiness = "RUNTIME_STATUS_UNKNOWN"
        elif requires_one_time_alignment:
            slash_readiness = "ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED"
        elif not fresh or not routing_valid:
            slash_readiness = "HANDSHAKE_REFRESH_REQUIRED"
        elif terminal_state:
            slash_readiness = "HANDSHAKE_REFRESH_REQUIRED"
        elif inventory_routable:
            slash_readiness = "SLASH_READY_FOR_NEW_GOAL"
        else:
            # Handshake present, fresh, valid, but no inventory-matched commands
            slash_readiness = "HANDSHAKE_REFRESH_REQUIRED"

        return slash_readiness
