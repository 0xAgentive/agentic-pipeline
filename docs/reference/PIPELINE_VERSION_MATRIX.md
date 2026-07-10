# Pipeline Version Matrix

This file records the public version posture of `agentic-pipeline`.

## Current public state

| Layer | Current version | Notes |
|---|---:|---|
| Package release | **1.2.3** | Distribution Integrity: state profiles, fresh-install smoke, command inventory, template hygiene, leakage checks, tracked-only release packages. |
| Canonical playbook/runtime | **1.2.0** | `docs/AGENTIC_PIPELINE_PLAYBOOK.md` and the versioned/reference copies remain byte-identical. |
| Runtime Truth patch | 1.2.1a | Fastpatch parity, schema baseline, evidence placeholders, self-contained hot workflows and runtime-truth validation. |
| Documentation cleanup | 1.2.2a | Historical patch label for bilingual GitHub landing and docs structure. It is not the runtime version. |
| ChatGPT Companion | 1.2.1 | Stored separately under `docs/companion/`. |
| Product Evidence Runtime | planned | Safe writers, artifact manifests and deterministic shipcheck are not yet fully active. |
| Runtime compiler | deferred | `runtime-src/` remains a scaffold until a deterministic compiler and drift validator exist. |

## Version rule

Use `VERSION.json` for machine-readable package/runtime/companion versions. Do not infer the active runtime from historical archive filenames.
