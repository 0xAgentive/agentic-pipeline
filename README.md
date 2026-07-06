# Agentic Development Pipeline for Google Antigravity

Version: `1.1.1`  
Status: public-audit package  
Primary runtime: Google Antigravity  
Primary shell support: Windows PowerShell, plus Bash helpers for repository operations and template adoption.

This repository packages a phase-gated agentic development pipeline for Google Antigravity. It contains the descriptive playbook, project template, workflows, rules, hook scripts, Codebase Memory MCP Windows workaround, script-gated `/fastpatch`, audit checklists, and bilingual usage instructions.

## Core model

```text
rules      = durable invariants
workflows  = command contracts
hooks      = deterministic guardrails
skills     = narrow expertise modules
MCP        = optional tool surface, not autopilot
.agy       = operational state and evidence ledger
```

## Quick start with Bash

```bash
git clone https://github.com/<OWNER>/<REPO>.git
cd <REPO>
bash scripts/bash/validate-package.sh
```

Adopt the pipeline into an existing project folder:

```bash
bash scripts/bash/adopt-pipeline.sh "/path/to/existing/project"
```

For Git Bash on Windows:

```bash
bash scripts/bash/adopt-pipeline.sh "/c/Users/<User>/Documents/antigravity/MyProject"
```

Then open the adopted project root in Antigravity and run:

```text
/landing
/codebase-map
/auditphase
```

## Windows PowerShell adoption

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\Apply-AgenticPipeline-v1.1.1.ps1 `
  -TargetRoot "$env:USERPROFILE\Documents\antigravity\MyProject" `
  -TemplateRoot ".\templates\agy-project-base" `
  -UpdateMcpConfig
```

## Public GitHub publication

```bash
bash scripts/bash/validate-package.sh
git init
git add .
git commit -m "Initial public release of Agentic Development Pipeline"
git branch -M main
git remote add origin https://github.com/<OWNER>/<REPO>.git
git push -u origin main
```

## Fastpatch policy

`/fastpatch` is not authorized by the model. It is authorized only by a deterministic script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1
```

If the script exits non-zero, use `/auditphase` or `/nextphase`.

## Codebase Memory on Windows

Do not use CLI `index_repository` as canonical. Do not create mirrors, junctions, `mklink`, `robocopy` duplicates, or `subst` drives. Use direct MCP JSON-RPC:

```powershell
node .\scripts\cbm-index-current-rpc.cjs
```

## License

MIT. Replace the copyright holder before publication if needed.
