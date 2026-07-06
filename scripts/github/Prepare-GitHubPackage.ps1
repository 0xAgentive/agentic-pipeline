param(
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Read-JsonFile {
  param([string]$Path)

  if (Test-Path $Path) {
    return (Get-Content $Path -Raw | ConvertFrom-Json)
  }

  return $null
}

function Write-IfMissing {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Content,
    [switch]$Overwrite
  )

  $dir = Split-Path $Path -Parent
  if ($dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
  }

  if ((Test-Path $Path) -and -not $Overwrite) {
    Write-Host "KEEP: $Path"
    return
  }

  Set-Content -Path $Path -Value $Content -Encoding UTF8
  Write-Host "WRITE: $Path"
}

function Get-ProjectTreeHint {
  $items = Get-ChildItem -Force | Where-Object {
    $_.Name -notin @(".git", "node_modules", "dist", "build", ".agy", ".agents", ".github")
  } | Select-Object -First 30

  if (!$items) {
    return "- TODO: describe project structure"
  }

  return (($items | ForEach-Object {
    if ($_.PSIsContainer) { "- $($_.Name)/" } else { "- $($_.Name)" }
  }) -join "`n")
}

function Get-NpmScriptsMarkdown {
  if (!(Test-Path "package.json")) {
    return "- No package.json detected. Add project-specific commands manually."
  }

  $pkg = Get-Content "package.json" -Raw | ConvertFrom-Json

  if (-not $pkg.scripts) {
    return "- package.json exists, but no scripts section was detected."
  }

  $lines = @()

  foreach ($p in $pkg.scripts.PSObject.Properties) {
    $lines += "- $($p.Name): $($p.Value)"
  }

  return ($lines -join "`n")
}

function Get-LicenseText {
  param([string]$LicenseName)

  $year = (Get-Date).Year
  $owner = "PROJECT_OWNER"

  try {
    $owner = gh api user -q ".login"
  } catch {}

  if ($LicenseName -eq "MIT") {
    return @"
MIT License

Copyright (c) $year $owner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the ""Software""), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED ""AS IS"", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"@
  }

  return "TODO: Add license text for $LicenseName."
}

$profile = Read-JsonFile ".agy\GITHUB_PROFILE.json"

if (!$profile) {
  throw "Missing .agy/GITHUB_PROFILE.json. Run the GitHub workflow installer first."
}

$title = $profile.project_title
if (!$title) {
  $title = Split-Path (Resolve-Path ".").Path -Leaf
}

$oneLiner = $profile.project_one_liner
if (!$oneLiner) {
  $oneLiner = "TODO: Add one-sentence project description."
}

$repo = $profile.repo
$visibility = $profile.visibility
$license = $profile.license
if (!$license) {
  $license = "MIT"
}

$treeHint = Get-ProjectTreeHint
$npmScripts = Get-NpmScriptsMarkdown
$overwrite = $Force.IsPresent
$folderName = Split-Path (Resolve-Path ".").Path -Leaf

Write-IfMissing "README.md" @"
# $title

$oneLiner

## Status

This repository was prepared for GitHub publication through an Antigravity workflow.

## What this project contains

$treeHint

## Quick start

Clone the repository:

    git clone https://github.com/$repo.git
    cd $folderName

Install and run project-specific commands as documented below.

## Available commands

$npmScripts

## Development workflow

Recommended local workflow:

    /landing
    /codebase-map
    /auditphase
    /nextphase
    /visualqa
    /securityaudit
    /shipcheck
    /githubsync

For GitHub synchronization, this repository uses:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1

GitHub MCP is not required.

## Repository

- GitHub: https://github.com/$repo
- Visibility: $visibility

## License

This project is licensed under the terms in LICENSE.
"@ -Overwrite:$overwrite

Write-IfMissing "README.ru.md" @"
# $title

$oneLiner

## Статус

Репозиторий подготовлен к выгрузке на GitHub через workflow Antigravity.

## Что содержит проект

$treeHint

## Быстрый старт

Клонирование:

    git clone https://github.com/$repo.git
    cd $folderName

Дальше используй команды проекта, описанные ниже.

## Доступные команды

$npmScripts

## Рабочий процесс разработки

Рекомендуемый локальный порядок:

    /landing
    /codebase-map
    /auditphase
    /nextphase
    /visualqa
    /securityaudit
    /shipcheck
    /githubsync

Для синхронизации с GitHub используется:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1

GitHub MCP не требуется.

## Репозиторий

- GitHub: https://github.com/$repo
- Видимость: $visibility

## Лицензия

Условия использования указаны в LICENSE.
"@ -Overwrite:$overwrite

Write-IfMissing "LICENSE" (Get-LicenseText -LicenseName $license) -Overwrite:$overwrite

Write-IfMissing "CHANGELOG.md" @"
# Changelog

All notable changes to this project should be documented here.

## Unreleased

- Prepared repository metadata and GitHub publication workflow.

## Initial release

- Initial GitHub-ready publication package.
"@ -Overwrite:$overwrite

Write-IfMissing "CONTRIBUTING.md" @"
# Contributing

Thank you for considering a contribution.

## Basic rules

- Open an issue or discussion before large changes.
- Keep pull requests focused.
- Do not include secrets, private data, raw telemetry, local databases, generated build output, or personal exports.
- Run available local checks before opening a PR.

## Pull request checklist

- [ ] The change has a clear purpose.
- [ ] Local checks pass.
- [ ] Documentation was updated when needed.
- [ ] Security/privacy impact was considered.
"@ -Overwrite:$overwrite

Write-IfMissing "SECURITY.md" @"
# Security Policy

## Reporting a vulnerability

Do not open a public issue for sensitive vulnerabilities.

Use GitHub private vulnerability reporting if enabled, or contact the maintainer through the private channel listed by the repository owner.

## Scope

Please report:

- secret exposure;
- unsafe file writes;
- privacy leaks;
- injection vulnerabilities;
- unsafe dependency or workflow behavior.
"@ -Overwrite:$overwrite

Write-IfMissing "CODE_OF_CONDUCT.md" @"
# Code of Conduct

Use professional, respectful communication.

Do not harass, threaten, abuse, or disclose private information.

Maintainers may remove comments, issues, or pull requests that are hostile, spammy, or unsafe.
"@ -Overwrite:$overwrite

Write-IfMissing ".gitignore" @"
# dependencies
node_modules/

# build outputs
dist/
build/
coverage/

# local env/secrets
.env
.env.*
*.pem
*.key
*.pfx
*.p12

# local databases / private data
*.sqlite
*.db
*.sqlite3

# logs / traces / archives
*.log
*.zip
*.har
*.trace

# Antigravity/runtime
.agy/*
!.agy/
!.agy/GITHUB_PROFILE.json
.codebase-memory/

# OS/editor
.DS_Store
Thumbs.db
.vscode/
"@ -Overwrite:$overwrite

Write-IfMissing ".gitattributes" @"
* text=auto eol=lf
*.ps1 text eol=crlf
*.cmd text eol=crlf
*.bat text eol=crlf
*.sh text eol=lf
*.md text eol=lf
*.json text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
"@ -Overwrite:$overwrite

Write-IfMissing ".github\ISSUE_TEMPLATE\bug_report.md" @"
---
name: Bug report
about: Report a reproducible problem
title: '[Bug]: '
labels: bug
assignees: ''
---

## Summary

## Steps to reproduce

1.
2.
3.

## Expected behavior

## Actual behavior

## Environment

- OS:
- Project version/commit:
- Node/npm or runtime version:

## Logs or screenshots

## Security/privacy impact

- [ ] No sensitive data included.
"@ -Overwrite:$overwrite

Write-IfMissing ".github\PULL_REQUEST_TEMPLATE.md" @"
## Summary

## Changes

## Verification

- [ ] Local tests/checks pass.
- [ ] Documentation updated if needed.
- [ ] No secrets/private data included.
- [ ] Security/privacy impact considered.

## Screenshots

If UI changed, attach screenshots or describe why not applicable.
"@ -Overwrite:$overwrite

Write-IfMissing ".github\workflows\validate.yml" @"
name: validate

on:
  pull_request:
  push:
    branches: [ main ]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check repository metadata
        shell: bash
        run: |
          test -f README.md
          test -f LICENSE
          test -f SECURITY.md
          test -f CONTRIBUTING.md
          test -f CHANGELOG.md
"@ -Overwrite:$overwrite

Write-IfMissing "docs\GITHUB_PUBLICATION.md" @"
# GitHub Publication Guide

## First publish

Run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode direct

## Update existing repository

Run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode direct -Message ""ship: update project""

## PR mode

Run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Sync-GitHub.ps1 -Mode pr -Message ""ship: update project""

## Safety

Never publish from the user profile root.

Check:

    Get-Location
    git status --short
"@ -Overwrite:$overwrite

Write-IfMissing "docs\RELEASE_CHECKLIST.md" @"
# Release Checklist

Before publishing:

- [ ] README.md exists and explains the project.
- [ ] LICENSE exists.
- [ ] SECURITY.md exists.
- [ ] CONTRIBUTING.md exists.
- [ ] CHANGELOG.md exists.
- [ ] .gitignore excludes secrets, local data, logs, archives, dependency folders, build outputs.
- [ ] .gitattributes defines line endings.
- [ ] Local checks pass.
- [ ] No secrets or private data are staged.
- [ ] git status --short was reviewed.
- [ ] Repository visibility is intentional.
"@ -Overwrite:$overwrite

Write-IfMissing "docs\AUDIT_CHECKLIST.md" @"
# Audit Checklist

## Repository metadata

- [ ] README.md
- [ ] README.ru.md if Russian-language users are expected
- [ ] LICENSE
- [ ] SECURITY.md
- [ ] CONTRIBUTING.md
- [ ] CHANGELOG.md
- [ ] CODE_OF_CONDUCT.md
- [ ] Issue template
- [ ] Pull request template

## Safety

- [ ] No .env files
- [ ] No tokens/secrets
- [ ] No local databases
- [ ] No raw private data
- [ ] No generated archives
- [ ] No dependency/build output

## Pipeline

- [ ] Antigravity workflows present
- [ ] GitHub sync script present
- [ ] Local checks pass
"@ -Overwrite:$overwrite

Write-Host ""
Write-Host "GitHub preparation complete."
Write-Host "Review generated files before publishing."
