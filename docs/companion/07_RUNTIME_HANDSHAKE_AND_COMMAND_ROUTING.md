# Runtime Handshake and Command Routing

The companion must not route execution from memory. It routes only from a current runtime handshake.

## Required handshake fields

```json
{
  "pipeline_package_version": "1.2.3",
  "runtime_version": "1.2.0",
  "project_root": "...",
  "workspace_root": "...",
  "git_root": "...",
  "state_root": ".../.agy",
  "artifact_root": ".../.artifacts",
  "available_commands": ["/auditphase", "/fixcritical"],
  "current_phase": "...",
  "current_status": "...",
  "next_required_command": "/auditphase",
  "commands_allowed_now": ["/auditphase"],
  "command_inventory_sha256": "...",
  "routing_valid": true
}
```

## Hard rules

1. A slash command absent from `available_commands` does not exist.
2. A command present in inventory but absent from `commands_allowed_now` is not currently allowed.
3. `next_required_command` must resolve to an available command.
4. If the handshake is unavailable or stale, provide a normal task pack or request a fresh handshake; do not emit an executable slash command.
5. Project root, Git root and state root must be explicit. Parent-workspace state must not be silently treated as project state.

## Default routing table

| Situation | Route |
|---|---|
| unclear or inconsistent claims/state | `/auditphase` |
| confirmed critical blockers from an audit | `/fixcritical` |
| state/handoff repair only | `/landing` |
| new approved implementation phase | `/nextphase` |
| bounded technical uncertainty | `/probephase` |
| small allowlisted change | `/fastpatch` only after gate |
| repair budget exhausted | human decision, no slash command |

## Staleness

A handshake is stale after relevant state, command inventory or Git root changes. Regenerate it before routing another phase.
