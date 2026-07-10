---
description: Produce a phase-gated implementation plan without changing product code.
---

# /planonly

## Goal

Create a bounded, verifiable phase plan from the current specification and repository state.

## Allowed writes

- `docs/IMPLEMENTATION_PLAN.md`
- `docs/VERIFICATION_PLAN.md`
- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agy/RECOVERY_PROMPT.md`

## Forbidden

- product-code implementation;
- dependency installation;
- broad formatting;
- commit, push, publish or ship claims.

## Required plan fields

For each phase: goal, allowed scope, forbidden scope, risk, checks, evidence, stop conditions, rollback and exact next command.

Stop after the plan. The next command is normally `/nextphase` or `/probephase`.
