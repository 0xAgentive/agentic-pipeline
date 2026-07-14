# Runtime Routing Acceptance Contract

This directory is an independent acceptance layer for Agentic Pipeline package 1.2.4 / runtime 1.2.1.

The first acceptance commit was created before runtime hardening. This corrective acceptance-judge commit closes four trust gaps found during independent review:

1. Schema validation no longer depends only on `companion-control.cjs`, which is implementation-owned.
2. Installer manifest production is tested, not only manifest consumption.
3. Installation identity is passed to the resolver as `installation_facts`, separate from command inventory.
4. Existing golden-eval case IDs are snapshotted before implementation and may not be deleted.

Protected paths are listed in `ACCEPTANCE_CONTRACT.json`. Runtime implementation must not modify them.

The acceptance suite deliberately fails against the pre-hardening candidate. Runtime implementation must make it pass without changing this directory or `.github/workflows/validate.yml`.

The test layers are:

- `runtime-routing-contract.cjs`: pure resolver behavior and golden-case preservation.
- `handshake-schema-contract.cjs`: protected, zero-dependency validation of the supported schema subset.
- `Test-RuntimeHandshakeAcceptance.ps1`: inventory provenance, Unicode paths, generated handshake, schema parity and product no-mutation.
- `Test-InstallationManifestAcceptance.ps1`: Windows and Bash installer manifest production.

`golden-cases-baseline.json` is generated from the candidate before runtime implementation. It freezes the original case IDs and count while still permitting additive golden cases and reviewed expectation corrections.

The workflow-directory fixture has a literal expected composite SHA-256:

`c9036e5d356c5b24845542431613e0287804084d242b40c5d9218fd56ccfece0`

This avoids testing an implementation only against another copy of the same algorithm.

## Final acceptance-lock corrections

The Phase A.2 lock closes the remaining two self-validation gaps:

- `evals/companion/golden_cases.json` is byte-frozen for Phase B using its recorded SHA-256, not only its case IDs.
- The protected schema judge asserts that the production handshake schema itself contains the mandatory fields, enums and strict object contracts. A weak implementation-owned schema is rejected before any generated handshake is validated.

Installer acceptance also requires a single cross-platform manifest writer:

`scripts/control-plane/write-installation-manifest.cjs`

Both Windows and Bash installers must invoke that helper. The helper must read `VERSION.json`; installer scripts must not embed the release version literals.
