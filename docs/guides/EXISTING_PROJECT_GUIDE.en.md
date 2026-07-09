# Existing Project Guide

Use this when a project already exists and you want to continue safely.

## Step 1. Read state

```powershell
Get-Content .agy\PHASE_STATUS.json -Raw
Get-Content .agy\AGENT_STATE.md -Raw
git status --short
```

## Step 2. Ask for a read-only audit if unsure

```text
/auditphase

Do not implement code.
Inspect current state, changed files, checks, risks and next required command.
Stop after the audit report.
```

## Step 3. Continue only with the expected command

If `PHASE_STATUS.json` says `/securityaudit`, do `/securityaudit`.
If it says `/shipcheck`, do `/shipcheck`.
If it says `/nextphase`, implement one planned phase.

## Step 4. Do not migrate pipeline mid-phase

A pipeline upgrade is an infrastructure task. Do it only when:
- current phase is complete;
- tests/build pass;
- git diff is understood;
- current state is not blocked.

## Step 5. For GitHub

First publication:

```text
/githubprepare
/githubsync
```

Updates:

```text
/githubsync
```
