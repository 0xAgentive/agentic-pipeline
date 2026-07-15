# Pipeline Version Matrix

This file records the public and candidate version posture of `agentic-pipeline`.

## Current state

| Layer | Current version | Notes |
|---|---:|---|
| Stable package release | **1.2.3** | Distribution Integrity on `main`: state profiles, fresh-install smoke, command inventory, template hygiene, leakage checks and tracked-only release packages. |
| Package candidate | **1.2.4** | Governance & Routing Stabilization: objective routing, independent acceptance, inventory trust, installation identity and cross-platform runtime checks. |
| Canonical playbook | **1.2.0** | `docs/AGENTIC_PIPELINE_PLAYBOOK.md` and the versioned/reference copies remain byte-identical. |
| Candidate runtime | **1.2.1** | Runtime handshake `1.1.0`, project-local inventory authority, explicit compatibility and fail-closed route derivation. |
| Runtime Truth patch | 1.2.1a | Historical patch label for fastpatch parity, schema baseline, evidence placeholders and runtime-truth validation. |
| Documentation cleanup | 1.2.2a | Historical patch label for bilingual GitHub landing and docs structure. It is not the runtime version. |
| ChatGPT Companion | 1.2.2 | Stored separately under `docs/companion/`; the companion version does not imply project migration. |
| Runtime compiler | deferred | `runtime-src/` remains a scaffold until a deterministic compiler and drift validator exist. |

## Compatibility rule

- Use `VERSION.json` for available package/runtime/companion versions.
- Use the project-local `.agy/INSTALLATION_MANIFEST.json` for installed package/runtime/source identity.
- A project-local command inventory is authoritative; the central inventory is advisory only.
- An exact runtime match is compatible. A mismatch requires migration unless an explicit compatibility matrix allows it.
- Unknown or malformed identity must remain unknown and must not be inferred from filenames, mutable state or a central inventory.