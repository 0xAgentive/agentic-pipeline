# Optional Example: Polar / H10 Lessons

This file is project-specific. Use only when discussing H10 Athlete Cardio Lab or similar local health-adjacent data products.

## Key product lesson

The app must separate:

1. Local App Analysis;
2. LLM Pack Mode;
3. LLM Diary.

LLM responses must never mutate deterministic metrics.

## Key safety lesson

Use non-diagnostic wording:

- candidate events;
- quality-limited;
- insufficient data;
- discuss with a professional if repeated or symptomatic.

Do not use:

- diagnosis;
- arrhythmia detected;
- no anomalies;
- clinical-grade;
- normal/abnormal as medical claim.

## Key artifact lesson

LLM Pack should be a flat ZIP with a manifest, SHA-256 checksums, clear time identity, privacy redaction, profile-specific file limits, and no full raw ECG/ACC by default.

## Key UI lesson

Visual and report quality are release gates, not cosmetics:

- readable dropdowns;
- no raw i18n keys;
- compact disclaimers;
- metric tooltips;
- no misleading 0% or raw broken values;
- report consistency;
- generated artifacts must be inspectable.
