# Changelog

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
