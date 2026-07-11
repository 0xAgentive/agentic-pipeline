# Optional Example: Domain-Specific Lessons

Load this file only when a project handles sensitive local data, research-grade evidence, health-adjacent observations, or another domain that requires stricter wording and artifact controls.

## Separation lesson

The product should separate:

1. deterministic local analysis;
2. export or handoff packages for an LLM;
3. free-form model commentary.

Model responses must never mutate deterministic metrics or overwrite machine-generated evidence.

## Safety lesson

Use bounded, non-diagnostic language:

- candidate event;
- quality-limited;
- insufficient data;
- requires independent review when repeated, consequential, or safety-sensitive.

Do not present a model interpretation as diagnosis, proof of absence, or production-grade validation.

## Artifact lesson

Evidence packages should use an explicit file list, a manifest, SHA-256 checksums, clear time identity, privacy redaction, profile-specific limits, and no unnecessary raw sensitive data by default.

## UI and report lesson

Visual and report quality are release gates, not cosmetics:

- readable controls;
- no raw localization keys;
- concise limitations;
- metric definitions and units;
- no misleading zero values or broken fallbacks;
- consistency between UI, reports, manifests, and machine-readable state;
- generated artifacts remain inspectable and reproducible.
