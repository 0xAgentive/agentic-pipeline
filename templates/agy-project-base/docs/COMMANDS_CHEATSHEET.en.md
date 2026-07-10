# Command Cheat Sheet

The canonical command inventory is `config/command-inventory.json`; every entry below has a distributed workflow.

## Specification and planning

- `/specdoc` - write or update product/specification documents only.
- `/planonly` - create a phased implementation and verification plan only.
- `/probephase` - run one bounded technical probe.

## Orientation and audit

- `/triage` - classify the request and recommend the next safe command.
- `/landing` - recover project orientation without implementation.
- `/auditphase` - read-only verification of state, claims, evidence and blockers.
- `/codebase-map` - build a bounded structural map of the codebase.
- `/parallel-audit` - run independent read-only audit lanes; no source writes.

## Implementation and repair

- `/nextphase` - implement exactly one approved phase and stop.
- `/fastpatch` - tiny script-gated UI/style patch with mandatory post-edit `-RequireChanges`.
- `/fixcritical` - fix only previously verified critical blockers.
- `/phasebatch` - disabled by default; requires explicit human unlock.
- `/lessons` - record candidate lessons without mutating durable runtime rules.

## Evidence gates

- `/visualqa` - validate UI evidence.
- `/reportqa` - validate reports and export bundles.
- `/securityaudit` - read-only security and privacy audit.
- `/artifactaudit` - verify artifact existence, index entries, size and hashes.
- `/shipcheck` - final evidence-based `SHIP` or `NO-SHIP` decision.

## GitHub publication

- `/githubprepare` - prepare bilingual repository metadata and publication files; no push.
- `/githubsync` - commit/push through deterministic local `git` and `gh` scripts.

## Stop conditions

Stop when the requested action does not match `.agy/PHASE_STATUS.json`, when deterministic evidence is missing, or when a write-capable tool requires approval.
