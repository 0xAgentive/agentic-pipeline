# Changelog

## 1.2.4 - Governance & Routing Stabilization

- Added a frozen, implementation-independent acceptance contract executed on Linux and Windows PowerShell 5.1.
- Made project-local command inventory authoritative and central inventory advisory-only.
- Added deterministic inventory provenance, trust classification and SHA-256 identity.
- Added installation-manifest package/runtime/source identity and explicit `compatible`, `migration_required` and `unknown` compatibility states.
- Reworked objective routing so state-declared routes are observations, slash-command arguments normalize before authorization, and unsafe or unproven states fail closed.
- Made `/shipcheck` non-circular and represented an existing SHIP decision as a terminal state.
- Upgraded the runtime handshake to schema `1.1.0` with structured staleness and routing reason codes.
- Added Unicode-safe Git-root resolution and cross-platform temporary paths for installation and handshake generation.
- Kept H10 product migration and product slash-command execution outside the framework release candidate.
## Companion 1.2.2 - Runtime Handshake and Bounded Repair

- Added runtime-handshake-gated command routing.
- Added frozen phase contracts, repair budgets, evidence levels and blocker taxonomy.
- Added independent status/finding lifecycle and machine-readable result authority.
- Added golden evals derived from real multi-domain project failure patterns.

## 1.2.3 - Distribution Integrity

- Added explicit `new-project` and `adopt-existing` state profiles.
- Added deterministic Windows project initializer with dry-run, conflict policy and installation manifest.
- Added canonical command inventory and distributed GitHub workflows/scripts.
- Added state-profile, command-inventory, template-hygiene, project-leakage and fresh-install validators.
- Added tracked-only release packaging with extraction validation, manifest and SHA-256.
- Removed generated checkpoint state from the public template.
- Added Windows PowerShell 5.1-safe zero-byte ledger validation and a regression guard for null-unsafe `Get-Content -Raw` method calls.

## 1.2.1a - Runtime Truth & Template Parity

- Enforced root/template fastpatch parity and post-edit `-RequireChanges`.
- Added runtime-truth validation, schema-aligned state baseline and self-contained hot workflows.
- Added companion Runtime Truth review policy.

## 1.1.1 - Public package and hotfix line

- Packaged playbook, template, scripts and bilingual instructions.
- Added Windows-safe MCP wrapper policy and script-gated `/fastpatch`.
