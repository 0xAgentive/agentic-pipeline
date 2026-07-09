# Pipeline Version Matrix

This file records the public version posture of `agentic-pipeline`.

## Current public state

| Layer | Status | Notes |
|---|---|---|
| Active canonical playbook | v1.2-family | `docs/AGENTIC_PIPELINE_PLAYBOOK.md` is the canonical root path for validators and downstream scripts. |
| Versioned playbook floor | v1.2.0 | The versioned playbook is preserved under `docs/maintainers/AGENTIC_PIPELINE_PLAYBOOK_v1.2.0.md`. The repository must not regress below the v1.2.0 playbook family. |
| Stabilization patch line | v1.1.1b-r4/r4b | r4/r4b are the stabilization and hardening patches for validation, fastpatch safety, path consistency and GitHub publication hygiene. |
| Human docs cleanup | v1.2.2a | GitHub landing pages and human documentation structure were cleaned up without changing runtime behavior. |
| ChatGPT Companion pack | v1.2.1 | Companion context is stored separately under `docs/companion/`. |
| Planned next-gen control plane | v1.2 Product Evidence Control Plane | Compiled runtime, full metrics/evals/evidence ledger and deeper product-contract gates are planned/maintainer-level work unless proven active by validators. |

## Important distinction

`v1.2.0` is the minimum current playbook family. `v1.2.2a` is a documentation/publication cleanup release. `v1.1.1b-r4/r4b` remains an important stabilization patch line and must stay visible in release notes and validators.

## Do not claim

Do not claim that compiled runtime, full eval suite, complete metrics ledger, or full Product Evidence Control Plane runtime is active by default unless the repository contains the corresponding scripts, schemas, validators and passing evidence.