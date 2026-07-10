# New Project Guide

Use the explicit `new-project` state profile. It starts at `/specdoc`.

## Windows

Dry-run:

```powershell
$Repo = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
$Project = "$env:USERPROFILE\Documents\antigravity\My New Project"
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode New -TargetRoot $Project
```

Apply after review:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode New -TargetRoot $Project -Apply
```

The installer copies a self-contained template, writes `.agy/INSTALLATION_MANIFEST.json`, and selects the schema-valid `new-project` state profile.

## Required first commands

```text
/specdoc
/planonly
/auditphase
/nextphase
```

Do not start implementation before specification and planning exist.
