# Distribution Integrity v1.2.3

This release keeps the canonical playbook/runtime at `1.2.0` and hardens how that runtime is installed, validated and packaged.

## Guarantees

- explicit `new-project` and `adopt-existing` state profiles;
- fresh-install validation from a copied template;
- command inventory parity between docs, workflows and scripts;
- template hygiene and project-leakage checks;
- tracked-only release archives built with `git archive`;
- extraction-time validation, package contents manifest and SHA-256.

## Version boundaries

- package release: `1.2.3`;
- canonical playbook/runtime: `1.2.0`;
- ChatGPT Companion: `1.2.1`;
- Runtime Truth patch: `1.2.1a`;
- historical documentation cleanup label: `1.2.2a`.

Empty evidence ledgers remain infrastructure only and do not prove readiness.

## PowerShell automatic-variable safety

`scripts/windows/Test-PowerShellRuntimeContracts.ps1` parses every distributed PowerShell file and rejects parameter names, assignments, or splats that collide with automatic variables such as `$args`. Native wrappers use explicit `ArgumentList` parameters.
