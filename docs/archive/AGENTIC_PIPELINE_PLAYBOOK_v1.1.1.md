# Agentic Development Pipeline Playbook

Version: `1.1.1`  
Date: `2026-07-06`  
Owner: `VB / User`  
Active runtime: `Google Antigravity only`  
Active model policy: `Gemini 3.5 Flash — Medium by default, High only for hard gates`  
Local mutation shell: `Windows PowerShell`  
Status: `hotfix release; v1.1.0 architecture preserved`

---

## 0. Executive Summary

This release is a narrow hotfix. It does not introduce a new agentic philosophy, a multi-track router, a product-probe system, or ROI telemetry. The v1.1.0 phase-gated architecture remains the baseline.

The v1.1.1 changes are limited to four operational needs:

```text
1. Windows MCP hardening through cmd.exe wrappers in C:\Users\Public\mcp-wrappers.
2. Codebase Memory Windows policy: do not use CLI index_repository; use MCP JSON-RPC reindexing when needed.
3. A script-gated /fastpatch path for a very small allowlisted UI surface only.
4. Deterministic semantic tests for critical projects such as H10; /shipcheck must trust exit codes, not model prose.
```

The main trust rule is:

```text
LLM reports are not verification.
Deterministic commands, tests, diffs, screenshots, logs, and exit codes are verification.
```

The core control principle remains:

```text
workflow = ordered execution contract
rules = durable project invariants
skills = narrow on-demand expertise
hooks = deterministic local guardrails/checkpoints
MCP = optional tool surface, never autopilot
project docs = human-readable source of truth
.agy = machine-readable state and evidence pointers, not truth itself
```

---

## 1. Active Scope

### 1.1 In scope

```text
Google Antigravity
Gemini 3.5 Flash Medium / High
PowerShell-only local mutation
Antigravity project templates
.agents workflows/rules/skills/hooks
.agy phase and evidence state
Context7 MCP
Codebase Memory MCP via Windows wrapper + RPC reindexing
Chrome DevTools MCP / Browser verification
GitHub MCP read-only after remote exists
agent-skills plugin if installed and useful
```

### 1.2 Out of active scope

```text
OpenAI Codex as active runtime
Claude Code / Cursor / Windsurf / Kiro / Aider
Autonomous cloud deployment
Write-capable MCP by default
Docker MCP Gateway as baseline
/router-style multi-track orchestration
/productprobe as a required workflow
METRICS.ndjson as a required system
instruction-smell linters as required infrastructure
```

Codex may exist as a historical note, but it is not part of the active runtime, default project template, or execution policy.

---

## 2. Platform and Model Baseline

Google Antigravity is the active platform baseline.

Older Gemini CLI references are compatibility notes only when a confirmed Antigravity equivalent exists. Do not let older Gemini/Codex conventions override project-local Antigravity workflows and state contracts.

Canonical model family:

```text
gemini-3.5-flash
```

Default thinking level:

```text
Medium
```

Use Medium for:

```text
routine implementation phases
ordinary audit loops
low-risk bug fixes
test-following corrections
localized UI changes
small refactors with clear acceptance criteria
```

Escalate to High for:

```text
architecture decisions
security/privacy audits
MCP policy changes
large cross-module refactors
stuck debugging after one failed repair
release / ship-no-ship decisions
state drift reconciliation
hook/workflow/template design
sensitive data or filesystem-safety work
```

After the hard decision is made, de-escalate back to Medium for ordinary implementation.

---

## 3. Trust Model

### 3.1 What counts as evidence

Accepted evidence:

```text
exit code 0 from deterministic command
failing exit code from a seeded or real regression
specific git diff
specific files changed
specific test output
specific build output
specific grep/search output
specific screenshot/video artifact
specific MCP JSON-RPC result when tool status is relevant
```

Not accepted as evidence by itself:

```text
LLM says “looks good”
LLM writes a long EVIDENCE_LOG entry
LLM says a test exists but did not run it
LLM says a security/privacy invariant is satisfied without a deterministic check
LLM claims release readiness without /shipcheck evidence
```

### 3.2 Ledger status

`.agy/EVIDENCE_LOG.md` is an audit pointer ledger. It is not source of truth. It should point to commands, outputs, artifacts, and residual risks.

For small approved `/fastpatch` work, use `evidence-lite` only:

```text
UTC:
Command:
Files:
Checks:
Result:
Risk class:
Next:
```

Do not let the agent write essays in the evidence ledger.

---

## 4. Workspace Layout

Canonical important-project layout:

```text
<ProjectRoot>\
  .agents\
    AGENTS.md
    agents.md                         # optional compatibility shim only
    hooks.json
    hooks\
      agy_checkpoint.ps1
      guard_preflight.ps1
      guard_context_budget.ps1
      guard_offline_local_only.ps1
      Test-HookContract.ps1
    rules\
      00-project-rules.md
      10-pipeline-rules.md
      20-safety-boundaries.md
      30-verification-gates.md
      40-mcp-tooling.md
      50-v1.1-governance.md
      51-v1.1.1-hotfix.md
    workflows\
      specdoc.md
      planonly.md
      auditphase.md
      probephase.md
      nextphase.md
      phasebatch.md
      fastpatch.md
      fixcritical.md
      landing.md
      visualqa.md
      securityaudit.md
      shipcheck.md
      lessons.md
      codebase-map.md
    skills\
      project-domain-accuracy\SKILL.md
      project-review-gate\SKILL.md
      <project-specific-skill>\SKILL.md

  .agy\
    PHASE_STATUS.json
    AGENT_STATE.md
    RECOVERY_PROMPT.md
    MCP_PROFILE.md
    EVIDENCE_LOG.md
    checkpoints\
    cbm\

  docs\
    PROJECT.md
    SPEC.md
    ARCHITECTURE.md
    DATA_SOURCES.md
    IMPLEMENTATION_PLAN.md
    VERIFICATION_PLAN.md
    RISKS_AND_ASSUMPTIONS.md
    EXECUTION_PROMPTS.md
    AGENTIC_PIPELINE_PLAYBOOK.md

  scripts\
    Test-FastPatchAllowed.ps1
    cbm-index-current-rpc.cjs
    cbm-wrapper-smoke.cjs

  AGENTS.md                         # short pointer only
  .gitignore
  .cbmignore
```

Root `AGENTS.md` is only a short pointer. Canonical runtime instructions live in `.agents/AGENTS.md`.

---

## 5. Phase-Gated Lifecycle

The standard lifecycle remains:

```text
/specdoc
/planonly
/auditphase
/probephase if needed
/nextphase one phase at a time
/visualqa if browser UI exists
/securityaudit if privacy/security/data-flow matters
/shipcheck
```

### 5.1 `/specdoc`

Specification documents only. No source code edits, scaffolding, dependency install, build/test/publish, feature implementation, or batch unlock.

### 5.2 `/planonly`

Implementation and verification plan only. No source code edits, scaffolding, dependency install, build/test/publish, feature implementation, or batch unlock.

### 5.3 `/auditphase`

Verify current workspace consistency before further work. Must check docs vs `.agy`, phase ledger freshness, build/test/lint commands if known, unverified claims, open risks, forbidden file mutations, and MCP/tool assumptions. No feature work.

### 5.4 `/probephase`

Validate local assumptions before implementation. Use for hardware/system APIs, large-file parsing, permissions, storage, network/source adapters, security/privacy-sensitive paths. No full product build.

### 5.5 `/nextphase`

One and only one phase. It must read `.agy/PHASE_STATUS.json`, verify approval, run preflight, implement only the selected phase, run targeted checks, review scope/security/privacy/regressions, fix only blockers, append evidence, checkpoint, and stop.

### 5.6 `/fastpatch`

A narrow, script-gated micro-workflow for low-risk UI/styling changes only.

It is not a router and not a model judgment path. The agent cannot self-authorize `/fastpatch` based on prose. It must pass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1
```

Allowed only when the script approves the current git diff.

Default H10 stance:

```text
Fastpatch is allowed only for explicitly allowlisted UI/styling files.
Any touched file outside the allowlist blocks fastpatch and requires /auditphase or /nextphase.
```

Forbidden in `/fastpatch`:

```text
backend code
analytics / HRV / QC logic
source ingestion
LLM Pack / export / redaction / sanitizer
reports / PDF / medical wording / disclaimers
storage / DB / migrations / schema
auth / secrets / env
package/dependency/build-tooling changes
hooks / workflows / templates / MCP config
.agy state changes except one evidence-lite entry
release-readiness claims
```

`/fastpatch` may append one compact evidence-lite entry. It must not run `/planonly`, `/auditphase`, `/codebase-map`, or broad scans.

If the fastpatch gate fails, stop and require the standard flow.

### 5.7 `/phasebatch`

Disabled by default. Maximum 2 low-risk adjacent phases only if explicitly enabled and no high-risk scope exists. Never default.

### 5.8 `/fixcritical`

Fix only blockers found by `/auditphase`, `/securityaudit`, `/visualqa`, or `/shipcheck`. No new features, redesigns, broad refactors, publish/package/signing, or speculative improvements.

### 5.9 `/landing`

Recovery only. Allowed: read status, summarize diff, update `.agy`, append evidence, checkpoint, stop. Forbidden: implementation, refactor, long commands, feature fixes.

### 5.10 `/visualqa`

Browser/UI verification only. Required evidence: tested URL/screen scope, screenshot path(s), console summary, network summary, visual defects or pass notes.

### 5.11 `/securityaudit`

Security/privacy audit only. Required evidence: grep/search results, test results, config findings, risk classification, unverified items.

### 5.12 `/shipcheck`

Release readiness only.

Must refuse “ready” if:

```text
.agy state is stale
EVIDENCE_LOG is missing or incomplete for material gates
build/tests are missing
semantic tests are required but absent or failing
visual QA required but absent
security audit required but absent
open high-risk risks exist
rollback notes are missing
```

For H10 and similarly sensitive projects, `/shipcheck` must require:

```text
npm run test:semantic
```

or the project’s equivalent deterministic semantic test command.

### 5.13 `/lessons`

Postmortem only. It writes candidate lessons to an inbox/patch proposal. It must not silently mutate durable rules, workflows, skills, or global instructions.

### 5.14 `/codebase-map`

Manual Codebase Memory use. Only after `.cbmignore` validation. No feature work.

On this Windows workspace, do not use Codebase Memory CLI `index_repository`. Use existing MCP index/query tools first; if reindexing is needed, use `scripts/cbm-index-current-rpc.cjs`.

---

## 6. Deterministic Semantic Verification

For critical projects, semantic verification must be implemented as ordinary tests, not as model review.

### 6.1 H10 Semantic Pack

Minimum H10 deterministic test groups:

```text
HRV/QC golden cases:
- RMSSD
- SDNN
- pNN50
- empty/short/constant RR intervals

LLM Pack redaction:
- no real username
- no local filesystem paths
- no Polar serial/device IDs
- no raw nested path leakage in ZIP exports

Medical wording:
- no clinical diagnostic claims
- disclaimer required in report/export/UI surfaces

Source log read-only:
- no writes, renames, temp files, or lock files under configured raw source roots such as Z:\Polar Logs

Sanitizer:
- strips script tags
- strips dangerous inline HTML
- preserves benign markdown

Local-only runtime:
- server binds to loopback
- no CDN/remote calls in frontend bundle
```

### 6.2 Fault injection

Fault injection is a human protocol, not an AI workflow.

Use a throwaway branch or worktree:

```text
1. create throwaway branch
2. manually introduce one known semantic defect
3. run npm run test:semantic or target test command
4. confirm non-zero exit code
5. revert/delete branch
```

Do not let the agent “prove” semantic tests by weakening assertions.

---

## 7. State and Evidence

Required state files:

```text
.agy/PHASE_STATUS.json
.agy/AGENT_STATE.md
.agy/RECOVERY_PROMPT.md
.agy/MCP_PROFILE.md
.agy/EVIDENCE_LOG.md
```

`PHASE_STATUS.json` minimum fields:

```json
{
  "project_name": "<ProjectName>",
  "current_policy": "one_phase_only",
  "batch_allowed": false,
  "project_status": "not_started|needs_independent_audit|in_progress|blocked|ready_candidate|shipped",
  "next_required_command": "/specdoc",
  "last_updated_utc": null,
  "last_audit_utc": null,
  "last_evidence_entry": null,
  "commands_allowed_now": [],
  "open_risks": [],
  "phases": []
}
```

Evidence policy:

```text
Full evidence for T2/T3 material gates.
Evidence-lite for script-approved /fastpatch only.
No long self-justifying essays.
Evidence points to deterministic outputs; it is not the output itself.
```

---

## 8. Hooks and Local Scripts

Hooks are deterministic local guardrails, not reasoning agents.

Rules:

```text
never block on interactive stdin
short runtime
clear timeout
no long indexing
no broad scans on critical path
stdout must be valid JSON when invoked by Antigravity
logs go to stderr or files
manual mode must not hang
```

Required hook scripts:

```text
agy_checkpoint.ps1
guard_preflight.ps1
guard_context_budget.ps1
guard_offline_local_only.ps1
Test-HookContract.ps1
```

Required non-hook utility scripts for v1.1.1:

```text
scripts/Test-FastPatchAllowed.ps1
scripts/cbm-index-current-rpc.cjs
scripts/cbm-wrapper-smoke.cjs
```

After template updates and before trusting hooks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\Test-HookContract.ps1"
```

---

## 9. Context and Indexing Controls

Baseline `.cbmignore`:

```text
node_modules/
dist/
build/
coverage/
.next/
.nuxt/
.turbo/
.vite/
.git/
.agy/checkpoints/
.pipeline_patch_backup/
.pipeline_sync_backup/
.pipeline_v1_1_backup/
.pipeline_adopt_backup/
.codebase-memory/
playwright-report/
test-results/
artifacts/
reports/generated/
logs/
tmp/
temp/
*.log
*.zip
*.pdf
*.html
*.har
*.trace
```

Do not globally ignore all `.json`, `.png`, `.md`, or fixtures. These may be source/config/test data.

---

## 10. MCP Governance

### 10.1 Default MCP stance

```text
read-only first
smallest tool surface
manual/project-triggered for heavy tools
no write-capable MCP without approval
no duplicate direct + gateway server for same purpose
no MCP as source of release truth
```

### 10.2 Windows wrapper model

Do not point Antigravity directly at binaries under a non-ASCII user profile path when a wrapper is available.

Preferred local wrapper directory:

```text
C:\Users\Public\mcp-wrappers
```

Preferred Codebase Memory cache:

```text
C:\Users\Public\codebase-memory-cache
```

Expected Codebase Memory server entry:

```json
{
  "codebase-memory": {
    "command": "C:\\Windows\\System32\\cmd.exe",
    "args": [
      "/d",
      "/c",
      "C:\\Users\\Public\\mcp-wrappers\\codebase-memory-mcp.cmd"
    ]
  }
}
```

Expected wrapper content:

```cmd
@echo off
setlocal

if "%LOCALAPPDATA%"=="" set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
set "CBM_EXE=%LOCALAPPDATA%\Programs\codebase-memory-mcp\codebase-memory-mcp.exe"

set "CBM_CACHE_DIR=C:\Users\Public\codebase-memory-cache"
set "CBM_LOG_LEVEL=error"
set "CBM_DIAGNOSTICS=0"
set "TEMP=C:\Users\Public\codebase-memory-temp"
set "TMP=C:\Users\Public\codebase-memory-temp"

if not exist "%CBM_EXE%" (
  echo Codebase Memory executable not found: "%CBM_EXE%" 1>&2
  exit /b 127
)

"%CBM_EXE%" %*
```

### 10.3 Codebase Memory Windows policy

On this Windows workspace:

```text
Do not use codebase-memory-mcp cli index_repository as canonical path.
Do not create repository mirrors.
Do not create junctions.
Do not run mklink.
Do not run robocopy to duplicate the repository.
Do not use subst.
Do not create C:\h10-athlete-cardio-lab.
```

If reindexing is needed, use:

```powershell
node .\scripts\cbm-index-current-rpc.cjs
```

Then use existing MCP query tools:

```text
list_projects
index_status
search_code
search_graph
get_architecture
trace_path if useful
```

### 10.4 Chrome DevTools MCP

Use only for `/visualqa` or explicit browser debugging.

Default privacy stance:

```text
separate clean browser profile if possible
no personal logins during QA
--no-usage-statistics
--no-performance-crux
screenshot evidence required
console/network notes required
```

---

## 11. Skills

Generic skills:

```text
project-domain-accuracy
project-review-gate
```

Project-specific skills are allowed only for repeating domain/safety risks.

H10 examples:

```text
h10-medical-language-safety
h10-llm-pack-security
h10-ingestion-readonly-guard
```

Skill hygiene:

```text
one narrow purpose
clear trigger description
explicit non-goals
short SKILL.md
no hidden shell snippets
no duplicated workflow text
version/owner if long-lived
```

Do not install broad skill packs into every project.

---

## 12. Required v1.1.1 Scripts

### 12.1 `scripts/Test-FastPatchAllowed.ps1`

This script must be project-specific. For H10, keep the allowlist deliberately narrow.

```powershell
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

$changed = @()
try {
  $changed += git diff --name-only --
  $changed += git diff --name-only --cached --
} catch {
  Write-Error "git diff failed; fastpatch denied"
  exit 1
}

$changed = $changed | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique

if ($changed.Count -eq 0) {
  Write-Host "No changed files. Fastpatch gate passes trivially."
  exit 0
}

# H10 conservative allowlist. Edit per project only after human review.
$allowed = @(
  '^src/frontend/components/AppSelect\.tsx$',
  '^src/frontend/components/OverlayRoot\.tsx$',
  '^src/frontend/styles/',
  '^src/frontend/.*\.css$'
)

$blocked = @()
foreach ($file in $changed) {
  $norm = $file -replace '\\','/'
  $ok = $false
  foreach ($rx in $allowed) {
    if ($norm -match $rx) { $ok = $true; break }
  }
  if (-not $ok) { $blocked += $file }
}

if ($blocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. These files are outside the approved allowlist:"
  $blocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

Write-Host "FASTPATCH ALLOWED. Changed files are inside the approved allowlist:"
$changed | ForEach-Object { Write-Host "- $_" }
exit 0
```

### 12.2 `scripts/cbm-index-current-rpc.cjs`

Use for Codebase Memory reindexing when needed. This script calls MCP JSON-RPC directly and avoids the Windows CLI `repo_path is required` failure mode.

### 12.3 `scripts/cbm-wrapper-smoke.cjs`

Use when MCP startup is suspected broken. It should call `list_projects` through the same `cmd.exe /d /c wrapper` path Antigravity uses.

---

## 13. Template and Project Validation

Validate template:

```powershell
$TemplateRoot = "$env:USERPROFILE\Documents\antigravity\_templates\agy-project-base"

Test-Path "$TemplateRoot\.agents\AGENTS.md"
Test-Path "$TemplateRoot\.agy\EVIDENCE_LOG.md"
Get-Content "$TemplateRoot\.cbmignore" -Raw
powershell -NoProfile -ExecutionPolicy Bypass -File "$TemplateRoot\.agents\hooks\Test-HookContract.ps1"
```

Validate active project:

```powershell
$ProjectRoot = "$env:USERPROFILE\Documents\antigravity\<ProjectName>"
Set-Location $ProjectRoot

powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\Test-HookContract.ps1"
Get-Content ".agy\PHASE_STATUS.json" -Raw | ConvertFrom-Json
Get-Content ".agy\EVIDENCE_LOG.md" -Raw
Get-Content ".cbmignore" -Raw
```

Validate MCP wrapper:

```powershell
cmd.exe /d /c "C:\Users\Public\mcp-wrappers\codebase-memory-mcp.cmd --version"
node .\scripts\cbm-wrapper-smoke.cjs
```

Validate fastpatch gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1
```

---

## 14. H10 Athlete Cardio Lab Current Rule

For current active H10 project:

```text
/codebase-map
/auditphase
/fixcritical only if blockers exist
/visualqa
/securityaudit
/shipcheck
```

Do not run:

```text
/phasebatch
/build auto
feature work
Codebase Memory CLI index_repository
mklink / junction / mirror / robocopy / subst for indexing
```

Current Codebase Memory stance:

```text
MCP server visible and responsive.
Existing RPC index usable.
Use list_projects and query tools.
Do not reindex unless necessary.
If reindexing is necessary, use scripts/cbm-index-current-rpc.cjs.
```

---

## 15. What Must Not Change

```text
Do not remove one-phase gating.
Do not make /phasebatch default.
Do not make Codebase Memory default for every project.
Do not replace tests with model review.
Do not allow write-capable MCP by default.
Do not scan dependency/generated folders as context.
Do not let planning write implementation files.
Do not let /landing become a fix/build command.
Do not silently mutate durable rules from /lessons.
Do not introduce /route, /productprobe, METRICS.ndjson, or instruction-smell linters as mandatory v1.1.1 work.
```

---

## 16. Changelog

### v1.1.1 — 2026-07-06

Changed:

```text
Kept v1.1.0 architecture intact; no v1.2.0 redesign.
Clarified that .agy evidence is an audit pointer, not source of truth.
Updated MCP config policy to Windows cmd.exe wrapper model.
Added Codebase Memory Windows policy: no CLI index_repository, no mklink/mirror/subst; use MCP JSON-RPC script.
Added script-gated /fastpatch with strict path allowlist.
Added deterministic semantic-test requirement for sensitive projects and H10 /shipcheck.
Rejected /route, /productprobe, METRICS.ndjson, and instruction-smell linting as mandatory current work.
```

### v1.1.0 — 2026-06-22

Changed:

```text
Narrowed active scope to Antigravity-only.
Moved Codex to historical/optional notes.
Normalized model policy around Gemini 3.5 Flash Medium/High.
Canonicalized .agents/AGENTS.md as runtime instruction surface.
Added append-only .agy/EVIDENCE_LOG.md.
Tightened /visualqa, /securityaudit, /shipcheck, /landing, /codebase-map contracts.
Expanded .cbmignore baseline.
Added hook self-test requirement.
Added Chrome DevTools MCP privacy flags.
Clarified Codebase Memory activation policy.
```

### v1.0.0 — 2026-06-22

Initial playbook with Antigravity workflows, `.agy` state, PowerShell-only mutation, MCP discipline, project templates, and phase gates.

---

## 17. Maintenance Cadence

Re-audit:

```text
after every major Antigravity update
after Gemini model/mode changes
after MCP server/config changes
after any pipeline failure or false-done incident
monthly for active templates
quarterly for stable baseline
```

Update contract:

```text
prefer deterministic project tests over new workflow text
preserve phase gates and local-first principle
propose minimal diff
include validation and rollback when scripts change
never add new mandatory meta-systems without measured need
```
