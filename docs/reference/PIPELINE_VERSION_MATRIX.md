# Pipeline Version Matrix

This file records the public version posture of `agentic-pipeline`.

## Current state

| Layer | Current version | Notes |
|---|---:|---|
| Package release | **1.2.5** | Flow Restoration & Scoped Assurance: work-item terminality, assurance modes, scoped execution leases, compact evidence and shadow rollout. |
| Previous stable package | 1.2.4 | Governance & Routing Stabilization: objective routing, independent acceptance, inventory trust, installation identity and cross-platform runtime checks. |
| Canonical playbook | **1.2.0** | `docs/AGENTIC_PIPELINE_PLAYBOOK.md` and the versioned/reference copies remain byte-identical. |
| Runtime | **1.2.2** | Additive Flow Restoration fields on handshake `1.1.0`, owner-approved work items, exact execution scope and degraded product execution. |
| Runtime Truth patch | 1.2.2a | Flow Restoration contracts, shadow routing and scoped assurance validation. |
| Documentation cleanup | 1.2.3a | Flow Restoration documentation and compact owner-facing policy. It is not the runtime version. |
| ChatGPT Companion | 1.2.3 | Compact semantic briefs, blocker materiality, autonomous current-scope repair and internal-only hashes. |
| Runtime compiler | deferred | `runtime-src/` remains a scaffold until a deterministic compiler and drift validator exist. |

## Compatibility rule

- Use `VERSION.json` for available package/runtime/companion versions.
- Use the project-local `.agy/INSTALLATION_MANIFEST.json` for installed package/runtime/source identity.
- A project-local command inventory is authoritative; the central inventory is advisory only.
- An exact runtime match is compatible. A mismatch requires migration unless an explicit compatibility matrix allows it.
- Unknown or malformed identity must remain unknown and must not be inferred from filenames, mutable state or a central inventory.
