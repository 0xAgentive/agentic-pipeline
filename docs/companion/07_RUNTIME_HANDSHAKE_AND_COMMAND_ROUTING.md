# Runtime Handshake and Command Routing

The companion must not route execution from memory. It routes only from a current, schema-valid runtime handshake produced for the target project.

## Runtime posture

- Package candidate: `1.2.4`
- Runtime: `1.2.1`
- Handshake schema: `1.1.0`
- Companion: `1.2.2`

## Representative handshake fields

The actual document is strict and contains all fields required by `schemas/companion/runtime-handshake.schema.json`. The following subset shows the trust and routing fields that control execution:

```json
{
  "schema_version": "1.1.0",
  "pipeline_package_version": "1.2.4",
  "runtime_version": "1.2.1",
  "project_root": "...",
  "git_root": "...",
  "git_state": "clean",
  "inventory_source": "project_command_inventory",
  "inventory_trust": "authoritative",
  "inventory_sha256": "<64 lowercase hex characters>",
  "installation_manifest_sha256": "<64 lowercase hex characters>",
  "installed_project_package_version": "1.2.4",
  "installed_project_runtime_version": "1.2.1",
  "available_pipeline_package_version": "1.2.4",
  "available_pipeline_runtime_version": "1.2.1",
  "runtime_compatibility": "compatible",
  "current_status": "acceptance_blocked",
  "state_declared_next_required_command": "/landing",
  "state_declared_commands_allowed_now": ["/landing"],
  "next_required_command": "/fixcritical",
  "resolved_commands_allowed_now": ["/auditphase", "/fixcritical"],
  "routing_mode": "normal",
  "routing_decision": "route",
  "routing_reason_codes": ["CONFIRMED_BLOCKER_REQUIRES_REPAIR"],
  "routing_valid": true
}
```

## Hard rules

1. Project-local inventory controls command existence. Central inventory metadata is advisory and cannot authorize execution.
2. State-declared `next_required_command` and `commands_allowed_now` are observations, not permissions.
3. Resolved routes come from objective Git, lifecycle, result, audit, blocker and repair-budget facts.
4. Dirty or stale recovery cannot authorize implementation, repair or shipping commands.
5. Missing, malformed, empty, duplicate or invalid project inventory fails closed and must not silently fall back.
6. Installed runtime identity comes from `.agy/INSTALLATION_MANIFEST.json`. Unknown identity remains unknown.
7. Runtime mismatch yields `migration_required` unless an explicit compatibility matrix permits the installed runtime.
8. A requested command with arguments is normalized to its root slash command before inventory and allowlist checks.
9. `/shipcheck` eligibility is derived before a final SHIP decision. An existing SHIP decision is terminal (`already_shipped`).
10. If routing validity, result authority or audit authority cannot be proven, do not emit an executable slash command.

## Objective lifecycle routes

| Objective condition | Route |
|---|---|
| specification required | `/specdoc` |
| planning required | `/planonly` |
| implementation ready | `/nextphase` with `/auditphase` as the read-only gate |
| implementation completed with authoritative result evidence | `/auditphase` |
| awaiting audit or fixed-unverified finding | `/auditphase` |
| confirmed current-phase blocker | `/fixcritical` within the repair budget |
| dirty, stale or recovery-required state | `/landing`, with `/auditphase` only where explicitly safe |
| release candidate with complete pre-ship evidence and no final decision | `/shipcheck` |
| final SHIP decision already present | terminal state, no command |
| missing authority, incompatible runtime or exhausted repair budget | fail closed or human decision |

## Staleness and reason codes

Staleness is represented by structured objects containing a machine-readable code, evidence and severity. Routing decisions also carry structured reason codes. Regenerate the handshake after relevant Git state, project inventory, installation identity, lifecycle state or result evidence changes.