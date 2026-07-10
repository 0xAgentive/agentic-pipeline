# Existing Project Adoption Guide

Do not adopt or upgrade the pipeline during active feature implementation.

## Preconditions

- the current product phase is complete;
- the worktree is clean or explicitly reviewed;
- tests/build status is understood;
- rollback or backup is available.

## Windows

Dry-run:

```powershell
$Repo = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
$Project = "C:\path\to\existing-project"
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode Adopt -TargetRoot $Project
```

Apply after review:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode Adopt -TargetRoot $Project -Apply
```

Default conflict policy is `Keep`. Existing files and `.agy` state are not silently replaced. New adoption state starts at `/landing`, followed by `/auditphase`.
