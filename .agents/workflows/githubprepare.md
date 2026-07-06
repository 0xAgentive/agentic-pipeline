---
description: Prepare a project for first GitHub publication by generating repository metadata, documentation, templates, and safety files.
---

# /githubprepare

Do not publish to GitHub.
Do not push.
Do not create a repository.

## Purpose

Prepare the current project directory for first GitHub publication.

Run this deterministic local script:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\github\Prepare-GitHubPackage.ps1

## Required output files

Ensure the project has:

- README.md
- README.ru.md when Russian-language usage is expected
- LICENSE
- CHANGELOG.md
- CONTRIBUTING.md
- SECURITY.md
- CODE_OF_CONDUCT.md
- .gitignore
- .gitattributes
- .github/ISSUE_TEMPLATE/bug_report.md
- .github/PULL_REQUEST_TEMPLATE.md
- .github/workflows/validate.yml
- docs/GITHUB_PUBLICATION.md
- docs/RELEASE_CHECKLIST.md
- docs/AUDIT_CHECKLIST.md
- .agy/GITHUB_PROFILE.json

## Rules

- Preserve existing files unless the user explicitly asks to overwrite.
- Do not include secrets, private data, local databases, raw telemetry, generated archives, logs, node_modules, dist, or build.
- If this is a public repository, verify that README, LICENSE, SECURITY, CONTRIBUTING, and CHANGELOG exist.
- If project-specific commands are known from package.json, mention them in README.
- If metadata is missing or unclear, insert TODO markers rather than inventing facts.

## After preparation

Report:

- files created;
- files kept unchanged;
- missing TODOs;
- repo profile;
- next command.

The next command should normally be:

    /githubsync
