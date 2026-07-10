---
description: Create or update the product specification without implementing code.
---

# /specdoc

## Goal

Turn the current request into a testable specification.

## Allowed writes

- `docs/SPEC.md`
- `docs/PROJECT.md`
- `.agy/PRODUCT_CONTRACT.json`
- `.agy/REQUIREMENTS_DELTA.md`
- state/evidence pointers under `.agy/`

## Forbidden

- source-code implementation;
- dependency changes;
- release claims;
- commits or pushes unless explicitly requested after review.

## Required output

- product goal and non-goals;
- acceptance criteria;
- privacy/security boundaries;
- required visual/report/artifact gates;
- unresolved questions and blockers;
- exact next command, normally `/planonly`.

Stop after the specification.
