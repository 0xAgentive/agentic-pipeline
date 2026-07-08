# Agentic Pipeline

A practical Antigravity-first workflow for building software with an AI agent without letting the agent drift, skip phases, or ship unsupported claims.

This repository is meant to answer one simple question:

> What do I tell the agent, in what order, and how do I know the result is safe enough to continue?

## Start here

English:
- [Start Here](docs/START_HERE.en.md)
- [New Project Guide](docs/NEW_PROJECT_GUIDE.en.md)
- [Existing Project Guide](docs/EXISTING_PROJECT_GUIDE.en.md)
- [Command Cheat Sheet](docs/COMMANDS_CHEATSHEET.en.md)

Russian:
- [Старт здесь](README.ru.md)
- [Быстрый старт](docs/START_HERE.ru.md)
- [Новый проект](docs/NEW_PROJECT_GUIDE.ru.md)
- [Действующий проект](docs/EXISTING_PROJECT_GUIDE.ru.md)
- [Шпаргалка команд](docs/COMMANDS_CHEATSHEET.ru.md)

## The pipeline in one sentence

Plan first, implement one phase at a time, verify with deterministic checks, keep evidence, then publish only after release gates pass.

## The normal flow

```text
raw idea
  -> /specdoc
  -> /planonly
  -> /auditphase
  -> /nextphase
  -> /visualqa if UI changed
  -> /securityaudit if data/privacy/security changed
  -> /shipcheck
  -> /githubprepare for first publication
  -> /githubsync for GitHub update
```

For small UI-only fixes, use `/fastpatch` only when the script gate allows it.

## Current operating rule

Do not apply a new pipeline version in the middle of an active feature phase. Finish the current phase, run audit/security/shipcheck, then migrate the project pipeline as a separate infrastructure phase.

## What this is not

This is not an autonomous coding bot that writes, verifies, publishes, and deploys everything without you. The human stays in the loop at phase boundaries and release gates.

## GitHub repository hygiene

A public repository should have a clear README, license, security policy, contribution notes, validation workflow, and simple getting-started instructions. This repository keeps those files in the root and detailed guides under `docs/`.
