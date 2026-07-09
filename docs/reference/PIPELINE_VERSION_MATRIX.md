# Pipeline Version Matrix

This repository uses `docs/AGENTIC_PIPELINE_PLAYBOOK.md` as the canonical latest playbook.

## Versions

| Version | Role | Status / Notes |
| --- | --- | --- |
| 1.0.0 | Historical baseline | Early ChatGPT Project → Antigravity → Codex-era playbook. |
| 1.1.0 | Antigravity-only baseline | Removed Codex from active runtime and tightened `.agents/.agy` governance. |
| 1.1.1 | Hotfix baseline | Preserved v1.1.0 architecture; added Windows MCP hardening, CBM RPC policy, script-gated `/fastpatch`, semantic verification rule. |
| 1.1.1a | Stable runtime | Current stable runtime baseline. Adds runtime contract without adding a new companion brain/state-machine layer. |
| 1.1.1b-r4/r4b | Stabilization patches | Active stabilization layer addressing immediate performance, path validation, and local developer environment issues. |
| 1.2.2a | Docs & Landing Cleanup | **Current Release**. Structural clean up of human-facing documentation, directories, and root GitHub landing pages. Does not alter runtime behavior or project templates. |
| 1.2 (Planned) | Product Evidence Control Plane | **Under Development / Scaffold stage**. Planned next-gen control plane introducing compiled runtimes, machine-readable evidence ledgers, and automated evaluations. *Not yet active by default.* |

## Canonical files

- Current: `docs/AGENTIC_PIPELINE_PLAYBOOK.md`
- Archive: `docs/archive/AGENTIC_PIPELINE_PLAYBOOK_v*.md`
- Runtime contract: `templates/agy-project-base/.agents/rules/05-runtime-contract.md`
- Companion prompt: `docs/COMPANION_SYSTEM_PROMPT_GPT55_v1.1.1a.md`

## Repository rule

Do not publish a release that only contains patch notes. The public repository must include the canonical latest playbook, archived prior versions, template files, workflows, rules, hooks, scripts, and installation/publication docs.
