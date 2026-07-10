# GitHub Publication Guide

## First publish

Run `/githubprepare`, review generated repository metadata, then run `/githubsync`.

The deterministic script is:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode direct

## Update existing repository

Run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode direct -Message "ship: update project"

## PR mode

Run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode pr -Message "ship: update project"

## Safety

Never publish from the user profile root.

Check:

    Get-Location
    git status --short