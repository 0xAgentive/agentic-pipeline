"""Shared local adapter for standby UI, bot, guard, supervisor and browser bridge.

Install adjacent to canonical runtime scripts. No network or process-control actions.
Owner methods are for existing authenticated command handlers, not model content.
"""
import json
import hashlib
import os
from pathlib import Path
import sqlite3
import uuid
from recovery_coordinator import Coordinator, MANUAL, Rejected, validate_state
from effect_owner import EffectOwner
from native_recovery import validate_live_binding
from runtime_paths import runtime_path

PROCESS_INSTANCE = str(uuid.uuid4())


def database_path():
    configured = os.environ.get("AGENTIC_RECOVERY_DB")
    if configured is not None and not configured.strip():raise Rejected("INVALID_DATABASE_PATH")
    return Path(configured) if configured else Path(runtime_path("AGENTIC_STATE_ROOT", "RECOVERY_STATE.sqlite3"))


def _database(database=None):
    path = Path(database) if database is not None else database_path()
    if not path.is_file():
        raise Rejected("NOT_INITIALIZED")
    return path


def snapshot(database=None):
    """Failures inhibit automation; do not overwrite malformed state with defaults."""
    try:
        path = _database(database)
        with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=2) as db:
            row = db.execute("SELECT data FROM state WHERE id=1").fetchone()
        state = json.loads(row[0]) if row else None
        return validate_state(state)
    except (OSError, sqlite3.Error, Rejected, ValueError, TypeError):
        return {"schema_version": 1, "epoch": None, "is_standby": True, "mode": "UNKNOWN", "reason": "STATE_UNAVAILABLE", "projects": {}, "last_pause_duration_sec": 0}


def owner_set(enabled, mode="MAN_IN_THE_MIDDLE", reason="", *, project=None, all_projects=False, expected_epoch=None, database=None):
    if type(enabled) is not bool:
        raise ValueError("enabled")
    c = Coordinator(_database(database))
    if enabled:
        if mode not in MANUAL:
            raise ValueError("owner pause mode")
        return c.pause(mode, reason=reason, project=project, expected_epoch=expected_epoch)
    # Direct fresh text/CLI resume may snapshot now; callbacks MUST pass displayed epoch.
    epoch = c.snapshot()["epoch"] if expected_epoch is None else expected_epoch
    return c.owner_resume(epoch, project=project, all_projects=all_projects)


def automatic_set(enabled, mode="QUOTA_EXHAUSTED", reason="", *, project=None, database=None):
    c = Coordinator(_database(database))
    if not enabled:
        # PID changes or a send-command exit code do not prove quota reset or recovery.
        return c.snapshot()
    return c.pause(mode, reason=reason, project=project)


def observe_runtime(instance, database=None):
    return Coordinator(_database(database)).observe_runtime(instance)


def validate_recovery_contract(action, work, binding, supported_routes):
    """Authorize only a still-active, bound work continuation; retained IDs are insufficient."""
    if not isinstance(action, dict) or action.get("auto_continue") is not True or action.get("owner_decision_required") is not False or not action.get("route"):
        raise Rejected("NO_ACTIVE_CONTINUATION")
    if not isinstance(supported_routes, (list, tuple)) or action["route"] not in supported_routes:
        raise Rejected("UNSUPPORTED_ROUTE")
    if not isinstance(work, dict) or not isinstance(binding, dict):
        raise Rejected("WORK_BINDING_REQUIRED")
    if work.get("owner_approved") is not True or work.get("hard_stop") is not False or work.get("status") in {"completed", "done", "closed", "cancelled", "failed", "blocked"}:
        raise Rejected("WORK_NOT_ACTIVE")
    for key in ["work_item_id", "goal_epoch"]:
        value = work.get(key)
        if not isinstance(value, (str, int)) or isinstance(value, bool) or value == "" or type(value) is not type(binding.get(key)) or value != binding[key]:
            raise Rejected("WORK_BINDING_MISMATCH")
    if type(action.get("work_item_id")) is not str or action["work_item_id"] != work["work_item_id"]:
        raise Rejected("WORK_ID_MISMATCH")
    return work["work_item_id"]


def dispatch_recovery(effect, project, work_id, event_id, failure_kind, *, database=None, expected_epoch=None):
    if not callable(effect) or not isinstance(work_id,str) or not work_id or not isinstance(event_id,str) or not event_id:raise ValueError("dispatch identity")
    owner=EffectOwner(_database(database));state=owner.coordinator.snapshot()
    binding=state.get("work_bindings",{}).get(project)
    current_work,current_action=validate_live_binding(binding)
    validate_recovery_contract(current_action,current_work,binding,binding.get("recovery_routes",[]))
    if work_id!=current_work["work_item_id"]:raise Rejected("WORK_BINDING_MISMATCH")
    context=hashlib.sha256(json.dumps([binding["work_item_sha256"],binding["next_action_sha256"]],separators=(",",":")).encode()).hexdigest()
    operation=hashlib.sha256(json.dumps([work_id,current_work["goal_epoch"],event_id],separators=(",",":")).encode()).hexdigest()
    epoch=state["epoch"] if expected_epoch is None else expected_epoch
    lease=owner.acquire(PROCESS_INSTANCE,project,event_id,epoch,context,"recovery",operation,work_item_id=work_id,goal_epoch=current_work["goal_epoch"],failure_kind=failure_kind)
    return _dispatch_effect(owner,lease,effect)


def _dispatch_effect(owner,lease,effect):
    owner.begin_effect(lease)
    try:
        result=effect()
    except BaseException:
        try:owner.ack(lease,outcome="UNCERTAIN")
        except Rejected:pass
        raise
    success=type(getattr(result,"returncode",None)) is int and result.returncode==0
    owner.ack(lease,outcome="SUCCEEDED" if success else "UNCERTAIN",receipt=getattr(result,"effect_receipt",None))
    return result


def dispatch_runtime_effect(effect, service, operation, *, database=None, expected_epoch=None):
    owner=EffectOwner(_database(database));state=owner.coordinator.snapshot()
    epoch=state["epoch"] if expected_epoch is None else expected_epoch
    context=hashlib.sha256(json.dumps([service,state.get("runtime_instance")],separators=(",",":")).encode()).hexdigest()
    lease=owner.acquire(PROCESS_INSTANCE,"__runtime__",operation,epoch,context,"runtime",operation)
    return _dispatch_effect(owner,lease,effect)


def import_legacy(legacy, seen_packets, database=None):
    """Offline cutover. Caller must already have quiesced all legacy state writers.

    Legacy PAUSED_BY_OWNER overwrote the turn phase; it requires receipt-based phase
    reconstruction before migration, never an unconditional READY_FOR_CONTEXT reset.
    """
    if not isinstance(seen_packets, dict):
        raise ValueError("invalid seen packets")
    for key, value in seen_packets.items():
        if isinstance(value, dict) and value.get("turnState") == "PAUSED_BY_OWNER":
            raise ValueError("PAUSED_BY_OWNER requires current-turn phase reconciliation: " + key)
    path = Path(database) if database is not None else database_path()
    return Coordinator(path).initialize(legacy)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Read-only browser/runtime state adapter")
    parser.add_argument("--database", type=Path)
    args = parser.parse_args()
    print(json.dumps(snapshot(args.database), ensure_ascii=False, separators=(",", ":")))
