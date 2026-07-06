# Runtime Agent Instructions

This file is the canonical runtime instruction surface for this Antigravity project.

Root `AGENTS.md` is only a short pointer and must not duplicate policy.

## Core execution policy
- Use `/specdoc` for specifications only.
- Use `/planonly` for planning only.
- Use `/auditphase` before trusting inherited or previously generated state.
- Use `/nextphase` for exactly one implementation phase.
- Keep `/phasebatch` disabled unless explicit unlock criteria pass.
- Use `/landing` for recovery only, not implementation.

## Evidence policy
Every substantial workflow must update:
- `.agy/PHASE_STATUS.json`
- `.agy/AGENT_STATE.md`
- `.agy/RECOVERY_PROMPT.md`
- `.agy/EVIDENCE_LOG.md`

Do not claim completion without commands/checks, pass/fail evidence, changed files, and remaining risks.

## Tool policy
Use the smallest tool surface.
Use Context7 for version-sensitive external docs.
Use Codebase Memory only for mature codebase structural questions after `.cbmignore` is verified.
Use Chrome DevTools/Browser only for explicit visual QA or browser debugging.
No write-capable MCP tools without explicit approval.
## Runtime Contract

Read `.agents/rules/05-runtime-contract.md` before substantial work. `.agy/PHASE_STATUS.json` defines the expected next workflow. Do not silently jump phases; use STATE CHECK when user intent conflicts with current state.
