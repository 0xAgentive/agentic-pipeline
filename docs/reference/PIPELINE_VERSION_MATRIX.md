# Pipeline Version Matrix

## Current state

| Layer | Current version | Notes |
|---|---:|---|
| Package release | **1.2.6** | Autonomous Audit Convergence: pre-write execution lease, complete first audit, stable finding deltas, bounded repair batches, protected reviewer and single closure compiler. |
| Previous stable package | 1.2.5 | Flow Restoration & Scoped Assurance. |
| Canonical playbook | **1.2.0** | The playbook remains compatible; the 1.2.6 change is in the executable governance layer. |
| Runtime | **1.2.3** | Adds execution-lease, convergence-budget, audit-coverage, reviewer and stage-firewall controls. |
| Runtime Truth patch | 1.2.3a | Autonomous-convergence validators and result-authority compiler. |
| Documentation cleanup | 1.2.4a | Compact Companion output and immutable-brief policy. |
| ChatGPT Companion | **1.2.4** | One initial brief, then finding/repair deltas; no repeated full task packs. |

## Compatibility

- Projects on runtime 1.2.2 remain readable but require a bounded runtime update before enforcing the new pre-write lease.
- Runtime 1.2.3 may start in `shadow` mode. A project becomes enforcing only after the project-local canary passes.
- Existing work items are not rewritten. The new controls apply to the next owner-approved work item unless explicitly adopted for an active item.
- Project-local command inventory remains command authority.
