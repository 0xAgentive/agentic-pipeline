---
description: Commit and push the current project to GitHub through deterministic git/gh commands. No GitHub MCP required.
---

# /githubsync

Do not implement features.
Do not edit source files.
Do not use GitHub MCP.

## Purpose

Synchronize this project with GitHub using the local deterministic script:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1

## Policy

Use only local deterministic commands:

- git status
- git add
- git commit
- git push
- gh repo create
- gh pr create
- gh repo view
- gh run list

## Preconditions

- /githubprepare has been run for first publication.
- gh auth status is valid.
- Current directory is not the user profile root.
- .gitignore is reviewed.
- Sensitive/generated files are not staged.
- Local checks pass unless the user explicitly uses -SkipChecks.

## Direct mode

Use direct mode for first publish and normal solo updates:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode direct

## PR mode

Use PR mode after the repository already exists, when you want a reviewable branch:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode pr

## Output

Report:

- repo URL;
- branch;
- commit hash;
- checks run;
- push result;
- next command.
