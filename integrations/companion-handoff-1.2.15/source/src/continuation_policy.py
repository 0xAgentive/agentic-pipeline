#!/usr/bin/env python3
"""
continuation_policy.py - Continuation Policy for Auto Context Handoff v4.3.4.

Computes the continuation readiness verdict based on result identity,
runtime status, and other verdicts. Implements work-item lifecycle
rules from spec sections 8, 22, 7.6.
"""

from typing import Dict, Any, Optional


def compute_continuation_policy(
    result_identity: Dict[str, Any],
    slash_readiness: str,
    conversation_verdict: str,
    implementation_verdict: str,
    identity_verdict: str,
    work_item_info: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Compute the CONTINUATION_POLICY.json structure.

    Args:
        result_identity: dict with work_item_id, implementation_status, verification_status, etc.
        slash_readiness: the slash_readiness verdict string
        conversation_verdict: conversation_resume_verdict string
        implementation_verdict: implementation_resume_verdict string
        identity_verdict: result_identity_verdict string
        work_item_info: optional additional work item metadata

    Returns:
        CONTINUATION_POLICY.json structure per spec section 22.
    """
    if work_item_info is None:
        work_item_info = {}

    prev_id = result_identity.get("work_item_id") or result_identity.get("id", "unknown")
    prev_impl = result_identity.get("implementation_status", "unknown")
    prev_verif = result_identity.get("verification_status", "unknown")

    # Normalize verification_status
    if identity_verdict == "NOT_APPLICABLE":
        prev_verif = "not_applicable"
    elif prev_verif in ("verified", "accepted", "passed", "completed"):
        prev_verif = "verified"
    elif prev_verif in ("blocked", "failed"):
        prev_verif = "blocked"
    else:
        prev_verif = "debt"

    # Determine if this is a VERIFICATION_DEBT case (spec section 7.4)
    # VERIFICATION_DEBT: historical work item, implementation done, evidence lost
    is_debt = (
        identity_verdict in ("VERIFICATION_BLOCKED", "VERIFICATION_DEBT", "NO_CURRENT_RESULT")
        and prev_impl in ("completed", "unknown")
    )
    if is_debt:
        prev_verif = "debt"

    # Determine runtime alignment state
    needs_alignment = slash_readiness in (
        "ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED",
        "RUNTIME_STATUS_UNKNOWN",
        "CONTEXT_BLOCKED",
    )
    needs_refresh = slash_readiness == "HANDSHAKE_REFRESH_REQUIRED"
    is_ready = slash_readiness in (
        "SLASH_READY_FOR_NEW_GOAL",
        "READY_AFTER_NEW_GOAL_BINDING",
    )
    is_na = slash_readiness == "NOT_APPLICABLE"

    # Default to BLOCKED
    readiness = "BLOCKED"
    new_allowed = False
    release_allowed = False
    runtime_action = "none"

    # Critical blockers first
    if implementation_verdict == "BLOCKED" and conversation_verdict == "BLOCKED":
        readiness = "BLOCKED"
    elif is_na:
        # Non-pipeline project: simple continuation
        if conversation_verdict in ("READY", "PARTIAL"):
            if implementation_verdict in ("READY", "NOT_APPLICABLE"):
                readiness = "READY_CURRENT_WORK_ITEM"
            else:
                readiness = "BLOCKED"
        else:
            readiness = "BLOCKED"
    elif needs_alignment:
        # Runtime alignment required
        runtime_action = "ONE_TIME_RUNTIME_ALIGNMENT_REQUIRED"
        if is_debt:
            readiness = "READY_AFTER_RUNTIME_ALIGNMENT"
            new_allowed = True
        elif prev_verif == "verified":
            readiness = "READY_AFTER_RUNTIME_ALIGNMENT"
            new_allowed = True
            release_allowed = True
        else:
            readiness = "READY_AFTER_RUNTIME_ALIGNMENT"
            new_allowed = True
    elif needs_refresh:
        # Handshake stale but runtime compatible
        runtime_action = "HANDSHAKE_REFRESH_REQUIRED"
        if is_debt:
            readiness = "READY_NEW_WORK_ITEM_WITH_VERIFICATION_DEBT"
            new_allowed = True
        elif identity_verdict == "ACCEPTED":
            readiness = "READY_NEW_WORK_ITEM"
            new_allowed = True
            release_allowed = True
        else:
            readiness = "READY_AFTER_RUNTIME_ALIGNMENT"
            new_allowed = True
    elif is_ready:
        # Runtime ready
        if identity_verdict == "ACCEPTED":
            readiness = "READY_NEW_WORK_ITEM"
            new_allowed = True
            release_allowed = True
        elif is_debt:
            readiness = "READY_NEW_WORK_ITEM_WITH_VERIFICATION_DEBT"
            new_allowed = True
        elif identity_verdict == "NOT_APPLICABLE":
            readiness = "READY_NEW_WORK_ITEM"
            new_allowed = True
        else:
            readiness = "READY_NEW_WORK_ITEM_WITH_VERIFICATION_DEBT"
            new_allowed = True

    if identity_verdict == "NOT_APPLICABLE":
        rel_eligibility = "not_applicable"
    else:
        rel_eligibility = "allowed" if release_allowed else "blocked"

    return {
        "previous_work_item": {
            "id": prev_id,
            "implementation_status": prev_impl,
            "verification_status": prev_verif,
            "release_eligibility": rel_eligibility,
        },
        "runtime_action": runtime_action,
        "new_work_item": {
            "allowed_after_runtime_action": new_allowed,
            "release_of_previous_result_allowed": release_allowed,
        },
        "continuation_readiness": readiness,
    }
