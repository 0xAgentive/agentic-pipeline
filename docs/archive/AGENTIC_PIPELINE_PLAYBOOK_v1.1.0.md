# Agentic Development Pipeline Playbook

Version: `1.1.0`  
Date: `2026-06-22`  .
Owner: `VB / User`  
Active runtime: `Google Antigravity only`  
Active model policy: `Gemini 3.5 Flash — Medium by default, High for hard gates`  
Local mutation shell: `Windows PowerShell`  
Status: `ready for operational use; re-audit after Antigravity/model/MCP updates`

---

## 0. Executive Summary

This playbook defines the current agentic software-development system used for local-first projects in Google Antigravity.

The system is intentionally phase-gated. Agents are not allowed to treat planning, implementation, testing, review, and release as one continuous task. Important projects move through explicit commands:

```text
raw idea
→ external specification/research pass
→ New-AgyProject PowerShell scaffold
→ /specdoc
→ /planonly
→ /auditphase
→ /probephase if local assumptions require validation
→ /nextphase one phase at a time
→ /visualqa if browser UI exists
→ /securityaudit if privacy/security/data-flow matters
→ /shipcheck
```

The core control principle is:

```text
workflow = ordered execution contract
rules = durable project invariants
skills = narrow on-demand expertise
hooks = deterministic local guardrails/checkpoints
MCP = optional tool surface, never autopilot
project docs = human-readable source of truth
.agy = machine-readable operational state and evidence ledger
```

This version removes Codex from the active runtime, normalizes the model policy around Gemini 3.5 Flash Medium/High, adds an evidence log, tightens Chrome DevTools/Browser and MCP governance, and introduces hook self-testing.

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
Codebase Memory MCP
Chrome DevTools MCP / Browser verification
GitHub MCP read-only after remote exists
agent-skills plugin if installed and useful
```

### 1.2 Out of active scope

```text
OpenAI Codex
Claude Code
Cursor
Windsurf
Kiro
Aider
Autonomous cloud deployment
Write-capable MCP by default
Docker MCP Gateway as baseline
```

Codex may exist as a historical or optional note, but it is not part of the active runtime, default project template, or execution policy.

---

## 2. Platform and Model Baseline

### 2.1 Platform baseline

Google Antigravity is the active platform baseline.

Older Gemini CLI references are compatibility notes only when a confirmed Antigravity equivalent exists. Do not let older Gemini/Codex conventions override project-local Antigravity workflows and state contracts.

### 2.2 Model policy

Canonical model family:

```text
gemini-3.5-flash
```

Antigravity UI labels such as `Medium` and `High` are treated as the effective thinking level unless local product verification proves they map to distinct model IDs.

Default:

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

## 3. Tool Roles

### 3.1 Antigravity

Primary implementation environment and workflow runner.

Used for:

```text
project execution
source edits
local commands
workflow execution
browser/UI verification when needed
MCP tool calls
artifact generation
```

### 3.2 External research/specification model

Used before Antigravity execution to transform raw ideas into an Agent Task Pack and to audit this playbook. It does not directly mutate the local project.

### 3.3 Context7 MCP

Use for fresh, version-sensitive external documentation.

Use when:

```text
external library behavior may have changed
framework setup/config is unclear
API syntax is version-sensitive
Node/React/Vite/SQLite/Windows/library docs are needed
```

Do not use for:

```text
local architecture discovery
small source edits
project-specific grep/search
already-known internal code
```

### 3.4 Codebase Memory MCP

Manual/project-triggered structural codebase tool.

Use when:

```text
project has roughly 30-50+ source files
cross-module impact analysis is needed
route/service/report dependencies matter
source-log read/write paths must be traced
repeated file reads/grep are inflating context
architecture map is needed before audit/refactor
```

Do not use for:

```text
raw idea → spec
empty greenfield projects
one-file edits
fresh external docs
visual UI QA
```

Mandatory before indexing:

```text
.cbmignore exists and is reviewed
```

### 3.5 Chrome DevTools MCP / Browser verification

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

### 3.6 GitHub MCP read-only

Use only after a remote repository exists and issues/PRs/actions/security metadata are relevant.

Never use write-capable GitHub tools without explicit approval.

### 3.7 Docker MCP Gateway

Not baseline. Optional appendix only for multi-server governance when Docker is already installed and reviewed.

---

## 4. Project Workspace Layout

Canonical template:

```text
C:\Users\Администратор\Documents\antigravity\_templates\agy-project-base
```

Canonical project root:

```text
C:\Users\Администратор\Documents\antigravity\<ProjectName>
```

Important project layout:

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
    workflows\
      specdoc.md
      planonly.md
      auditphase.md
      probephase.md
      nextphase.md
      phasebatch.md
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

  AGENTS.md                         # short pointer only
  .gitignore
  .cbmignore
```

---

## 5. Runtime Instruction Surface

Canonical runtime instructions live in:

```text
.agents/AGENTS.md
```

Root `AGENTS.md` is only a short pointer:

```text
Canonical runtime instructions live in .agents/AGENTS.md.
Do not duplicate project policy here.
```

If `.agents/agents.md` already exists, keep it only as a compatibility shim. Do not let it diverge from `.agents/AGENTS.md`.

Do not duplicate workflow content in rules or AGENTS files. Rules define invariants; workflows define execution sequences.

---

## 6. Phase-Gated Lifecycle

### 6.1 `/specdoc`

Purpose: specification documents only.

Allowed:

```text
docs/PROJECT.md
docs/SPEC.md
docs/ARCHITECTURE.md
docs/DATA_SOURCES.md
docs/RISKS_AND_ASSUMPTIONS.md
docs/EXECUTION_PROMPTS.md
.agy state files
```

Forbidden:

```text
source code edits
scaffolding
dependency install
build/test/publish
feature implementation
batch unlock
```

### 6.2 `/planonly`

Purpose: implementation and verification plan only.

Allowed:

```text
docs/IMPLEMENTATION_PLAN.md
docs/VERIFICATION_PLAN.md
docs/EXECUTION_PROMPTS.md
.agy/PHASE_STATUS.json
.agy/AGENT_STATE.md
.agy/RECOVERY_PROMPT.md
.agy/EVIDENCE_LOG.md
```

Forbidden:

```text
source code edits
scaffolding
dependency install
build/test/publish
feature implementation
batch unlock
```

### 6.3 `/auditphase`

Purpose: verify current workspace consistency before further work.

Must check:

```text
docs vs .agy state
phase ledger freshness
build/test/lint commands if known
unverified claims
open risks
forbidden file mutations
MCP/tool usage assumptions
```

Output must update:

```text
.agy/PHASE_STATUS.json
.agy/AGENT_STATE.md
.agy/RECOVERY_PROMPT.md
.agy/EVIDENCE_LOG.md
```

No feature work.

### 6.4 `/probephase`

Use for local capability validation before implementation.

Required for:

```text
hardware/system APIs
large-file parsing
filesystem permissions
database/storage assumptions
network/source adapters
security/privacy-sensitive paths
```

No full product build.

### 6.5 `/nextphase`

One and only one phase.

Must:

```text
read .agy/PHASE_STATUS.json
verify phase is approved
run preflight
implement only selected phase
run targeted checks
review scope/security/privacy/regressions
fix only blocking issues
append evidence
checkpoint
stop
```

### 6.6 `/phasebatch`

Disabled by default.

May be enabled only when:

```text
batch_allowed=true
two previous /nextphase runs passed
no open high-risk audit findings
no security/privacy/data-loss scope
no new dependency/tooling changes
low inter-phase coupling
diff budget is small
```

Maximum: 2 low-risk adjacent phases.

Never default.

### 6.7 `/fixcritical`

Fix only blockers found by `/auditphase`, `/securityaudit`, `/visualqa`, or `/shipcheck`.

Forbidden:

```text
new features
redesign
broad refactor
publish/package/signing
speculative improvements
```

### 6.8 `/landing`

Recovery only.

Allowed:

```text
read status
summarize diff
update .agy
append evidence
checkpoint
stop
```

Forbidden:

```text
implementation
refactor
long commands
feature fixes
```

### 6.9 `/visualqa`

Browser/UI verification only.

Required evidence:

```text
tested URL/screen scope
screenshot path(s)
console summary
network summary
visual defects or pass notes
```

No feature work unless explicitly approved after QA findings.

### 6.10 `/securityaudit`

Security/privacy audit only.

Required evidence:

```text
grep/search results
test results
config findings
risk classification
unverified items
```

No unsupported “secure” claims.

### 6.11 `/shipcheck`

Release readiness only.

Must refuse “ready” if:

```text
.agy state is stale
EVIDENCE_LOG is missing or incomplete
build/tests are missing
visual QA required but absent
security audit required but absent
open high-risk risks exist
rollback notes are missing
```

### 6.12 `/lessons`

Postmortem only.

It writes candidate lessons to an inbox/patch proposal. It must not silently mutate durable rules, workflows, skills, or global instructions.

### 6.13 `/codebase-map`

Manual Codebase Memory use.

Only after `.cbmignore` validation.

No feature work.

---

## 7. State and Evidence

### 7.1 Required state files

```text
.agy/PHASE_STATUS.json
.agy/AGENT_STATE.md
.agy/RECOVERY_PROMPT.md
.agy/MCP_PROFILE.md
.agy/EVIDENCE_LOG.md
```

### 7.2 Required `PHASE_STATUS.json` fields

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

### 7.3 `EVIDENCE_LOG.md`

Append-only.

Every substantial command appends:

```text
UTC timestamp
command run
model/thinking level if known
MCP/tools used
files changed
commands/checks executed
artifacts produced
skipped checks with reason
residual risks
next required command
```

---

## 8. Hooks

### 8.1 Hook principles

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

### 8.2 Required hook scripts

```text
agy_checkpoint.ps1
guard_preflight.ps1
guard_context_budget.ps1
guard_offline_local_only.ps1
Test-HookContract.ps1
```

### 8.3 Hook self-test

Run after template updates and before trusting hooks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\Test-HookContract.ps1"
```

---

## 9. Context and Indexing Controls

### 9.1 `.cbmignore` baseline

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

### 9.2 Do not globally ignore all `.json`, `.png`, `.md`, or fixtures

These may be source/config/test data.

---

## 10. MCP Governance

### 10.1 Default MCP stance

```text
read-only first
smallest tool surface
manual/project-triggered for heavy tools
no write-capable MCP without approval
no duplicate direct + gateway server for same purpose
```

### 10.2 Current expected global MCP config

```json
{
  "mcpServers": {
    "chrome-devtools-mcp": {
      "command": "C:\\Users\\Администратор\\AppData\\Roaming\\npm\\chrome-devtools-mcp.cmd",
      "args": ["--no-usage-statistics", "--no-performance-crux"]
    },
    "context7": {
      "serverUrl": "https://mcp.context7.com/mcp"
    },
    "codebase-memory": {
      "command": "C:\\Users\\Администратор\\AppData\\Local\\Programs\\codebase-memory-mcp\\codebase-memory-mcp.exe",
      "args": []
    }
  }
}
```

### 10.3 Record material MCP usage

Every material MCP use must be reflected in:

```text
.agy/MCP_PROFILE.md
.agy/EVIDENCE_LOG.md
```

---

## 11. Skills

### 11.1 Generic skills

```text
project-domain-accuracy
project-review-gate
```

### 11.2 Project-specific skills

Use only when a project has a repeating domain/safety risk.

Example H10 skills:

```text
h10-medical-language-safety
h10-llm-pack-security
h10-ingestion-readonly-guard
```

### 11.3 Skill hygiene

Each skill must have:

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

## 12. Template Update and Validation

### 12.1 Create new project

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Documents\antigravity\_templates\New-AgyProject.ps1" `
  -Name "<ProjectName>"
```

### 12.2 Validate template

```powershell
$TemplateRoot = "$env:USERPROFILE\Documents\antigravity\_templates\agy-project-base"

Test-Path "$TemplateRoot\.agents\AGENTS.md"
Test-Path "$TemplateRoot\.agy\EVIDENCE_LOG.md"
Get-Content "$TemplateRoot\.cbmignore" -Raw
powershell -NoProfile -ExecutionPolicy Bypass -File "$TemplateRoot\.agents\hooks\Test-HookContract.ps1"
```

### 12.3 Validate active project

```powershell
$ProjectRoot = "$env:USERPROFILE\Documents\antigravity\<ProjectName>"
Set-Location $ProjectRoot

powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\Test-HookContract.ps1"
Get-Content ".agy\PHASE_STATUS.json" -Raw
Get-Content ".agy\EVIDENCE_LOG.md" -Raw
Get-Content ".cbmignore" -Raw
```

---

## 13. H10 Athlete Cardio Lab Current Rule

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
```

until the independent audit has regenerated evidence and no high-risk blockers remain.

---

## 14. What Must Not Change

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
```

---

## 15. Changelog

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

## 16. Maintenance Cadence

Re-audit:

```text
after every major Antigravity update
after Gemini model/mode changes
after MCP server/config changes
after any pipeline failure or false-done incident
monthly for active templates
quarterly for stable baseline
```

Deep Research update contract:

```text
verify current tool docs
identify obsolete assumptions
propose minimal diff
return PowerShell patch commands
include validation and rollback
preserve phase gates and local-first principle
```
