# Context Split: ChatGPT Companion and Antigravity Pipeline

This system has two connected products.

## 1. ChatGPT Project companion

Purpose:

- turn raw ideas into specifications;
- prepare Agent Task Packs;
- review other models' proposals;
- audit logs, screenshots, artifacts and claims;
- produce exact next Antigravity prompts;
- not execute repository changes.

## 2. Antigravity pipeline repository

Purpose:

- host the public framework;
- host the project template;
- host workflows, rules, hooks and scripts;
- publish GitHub-ready documentation;
- provide a simple start for other users.

## 3. Active project workspace

Purpose:

- host product source code;
- hold project-specific `.agy` state;
- execute one phase at a time;
- produce tests, evidence and artifacts.

## Rule

Do not copy everything everywhere.

- Companion owns reasoning, research and task framing.
- Pipeline owns executable docs/templates/scripts.
- Active projects receive only project-relevant files through a separate migration phase.

## When to migrate an active project

Only after:

1. the current phase is complete;
2. tests/builds are green;
3. `.agy/PHASE_STATUS.json` matches reality;
4. `/auditphase` confirms a safe window;
5. `/planonly` creates a migration plan.

Do not migrate pipeline runtime in the middle of active feature work.
