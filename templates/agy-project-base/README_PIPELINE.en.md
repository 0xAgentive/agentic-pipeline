# How to use this template

This is the base Antigravity project template.

## New project

1. Copy the template into a new folder.
2. Open the folder in Antigravity.
3. Run `/specdoc`.
4. Then `/planonly`.
5. Then `/nextphase`, one phase at a time.

## Existing project

If the project already exists, first check:

```powershell
Get-Content .agy\PHASE_STATUS.json -Raw
git status --short
```

If unsure:

```text
/auditphase
```

## Main rule

The agent must not silently jump to the next phase. It implements one phase, runs checks, updates state, and stops.
