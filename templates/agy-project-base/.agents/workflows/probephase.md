---
description: Perform a bounded technical probe before implementation.
---

# /probephase

## Goal

Resolve one concrete uncertainty about an API, dependency, device, data format, permission, performance assumption or integration boundary.

## Rules

- keep the probe minimal and reversible;
- do not implement the full feature;
- do not modify sensitive/raw source data;
- use local fixtures where possible;
- record exact commands, outputs and conclusions.

## Allowed writes

- a small disposable probe under an approved test/probe directory;
- `.agy` state and evidence pointers.

## Output

Pass/fail conclusion, evidence, remaining uncertainty, cleanup/rollback and exact next command.

Stop after the probe.
