
Version: `1.0.0`  
Date: `2026-06-22`  
Owner: `VB / User`  
Primary execution environment: `Windows + PowerShell + Google Antigravity`  
Secondary/reviewer environment: `OpenAI Codex`  
Document purpose: transfer the full current workflow state to another Deep Research model so it can audit and improve the system.

---

## 0. Executive Summary

We use a two-layer development system:

1. **ChatGPT Project** is the specification compiler, research verifier, and orchestration planner.
    
2. **Antigravity** is the implementation agent inside a project workspace.
    
3. **Codex** is a secondary reviewer/executor when `AGENTS.md` and sandbox/approval controls are useful.
    
4. **MCP tools** are contextual tools, not autopilot. They are used only when they reduce uncertainty or context cost.
    
5. **PowerShell** is the only accepted way to mutate the local system, templates, MCP config, hooks, and project scaffolding.
    

The core lesson from our experiments: agents can build fast, but they do not reliably preserve phase boundaries unless the project gives them explicit workflows, state files, hooks, and stop conditions.

Canonical pipeline:

```text
Raw idea
→ ChatGPT Project compiles Agent Task Pack
→ New-AgyProject creates workspace from template
→ Antigravity /specdoc
→ /planonly
→ /auditphase
→ /probephase if needed
→ /nextphase repeated one phase at a time
→ /visualqa and /securityaudit for UI/data/security projects
→ /shipcheck
```

For risky projects, `/phasebatch` and `/build auto` are disabled until audit/probe gates pass.

---

## 1. Current Tooling Stack and Roles

### 1.1 ChatGPT Project

Role:

```text
Specification compiler
Research verifier
Agent orchestration planner
Prompt generator
Pipeline auditor
```

It does not implement code directly. It turns raw ideas into an **Agent Task Pack**.

Expected model/runtime:

```text
GPT-5.5 / GPT-5.5 Pro
Reasoning: Very High
Language to user: Russian
Hidden analysis/research planning: English allowed
```

### 1.2 Google Antigravity

Role:

```text
Primary implementation agent
Project workspace executor
UI/browser verification agent when needed
Artifact producer
```

Target focus version:

```text
Antigravity 2.1.4 unless locally verified otherwise
```

Must be verified per machine:

```powershell
agy --version
agy plugin list
```

### 1.3 OpenAI Codex

Role:

```text
Secondary reviewer
Alternative executor
Independent code audit
Security/release review
```

Target focus version:

```text
Codex 26.602.9276.0 unless locally verified otherwise
```

Codex-specific guidance lives in `AGENTS.md`.

### 1.4 agent-skills plugin

Role:

```text
Lifecycle engineering discipline:
spec → planning → build → test → review → simplify → ship
```

Use explicit slash commands for normal lifecycle work, but for high-risk Antigravity projects our custom workflows override generic `/build auto`.

Typical commands exposed by the plugin:

```text
/spec
/planning
/build
/test
/review
/code-simplify
/ship
/webperf
```

Local convention:

```text
Use /planning, not /plan, in Antigravity, to avoid command ambiguity.
```

### 1.5 Context7 MCP

Role:

```text
Fresh, version-specific docs/API behavior
```

Use for:

```text
.NET, Node, React, Vite, SQLite, Windows APIs, packaging,
library-specific APIs, framework changes, SDK behavior.
```

Do not use for:

```text
Local architecture discovery
Routine file search
Known project-specific code
```

### 1.6 Codebase Memory MCP

Role:

```text
Local structural codebase knowledge graph
Architecture map
Impact analysis
Call graph
Route/service/report dependency tracing
Source-log read/write path audit
```

Use when:

```text
Project has ~30–50+ source files
Agent starts losing architectural context
Audit/refactor/impact analysis requires cross-module tracing
We need to find all code paths touching a sensitive resource
```

Do not use for:

```text
Raw idea → ТЗ
/specdoc on empty project
Small one-file edits
Fresh external documentation
Visual UI verification
```

Mandatory before use:

```text
.cbmignore must exist and exclude node_modules, dist, .git, .agy/checkpoints, backups, logs, generated exports.
```

Canonical `.cbmignore`:

```text
node_modules/
dist/
.git/
.agy/checkpoints/
.pipeline_patch_backup/
.pipeline_sync_backup/
.codebase-memory/
coverage/
*.log
*.zip
*.pdf
*.html
```

Verification:

```powershell
codebase-memory-mcp --version
Get-Content "$env:USERPROFILE\.gemini\config\mcp_config.json" -Raw
```

### 1.7 Chrome DevTools / Browser Subagent

Role:

```text
UI runtime verification
Screenshots
Browser recordings
Console/network checks
Accessibility smoke checks
```

Use for:

```text
React/Vite/browser UI projects
Visual QA
Console errors
Network mistakes
Dark theme/readability
Dialogs/selects/dropdowns
Keyboard navigation
```

Do not use for:

```text
Desktop WPF/WinUI-only projects
Backend-only tasks
Raw idea/spec work
```

### 1.8 GitHub MCP read-only

Role:

```text
Remote repo metadata
Issues
Pull requests
Actions logs
Code scanning metadata
```

Use only after:

```text
Remote repository exists
Issues/PRs/Actions are relevant
Read-only token is configured
```

Never use write-capable GitHub tools without explicit approval.

### 1.9 Docker MCP Gateway

Role:

```text
Centralized MCP profile/gateway governance
```

Use only when:

```text
Multiple MCP servers need centralized profile management
Docker is installed and stable
Credential/tool routing needs gateway controls
```

Do not use for small local projects or early greenfield setup.

---

## 2. Global Principles

### 2.1 Phase boundaries are explicit

The agent must never decide that planning, building, testing, reviewing, and shipping are one continuous task.

We separate:

```text
/specdoc    = documentation only
/planonly   = planning only
/auditphase = audit only, no features
/probephase = local probe only
/nextphase  = exactly one implementation phase
/phasebatch = 1–2 low-risk phases only after explicit enablement
/shipcheck  = release readiness only, no features
```

### 2.2 Evidence beats claims

A phase is not done unless it includes:

```text
Changed files
Commands/checks run
Pass/fail output
Skipped checks with reason
Remaining risks
Exact next command
Updated .agy state
```

### 2.3 State is explicit

Every substantial project maintains:

```text
.agy/PHASE_STATUS.json
.agy/AGENT_STATE.md
.agy/RECOVERY_PROMPT.md
.agy/MCP_PROFILE.md
.agy/checkpoints/
```

The agent must update these after each phase.

### 2.4 PowerShell-only local mutation

All local setup, repair, scaffolding, hooks, MCP config, template updates, and environment configuration are done through PowerShell.

No manual file mutation is preferred when a safe script can do it.

### 2.5 Minimum effective context

Avoid context bloat:

```text
Do not scan node_modules, dist, .git, generated reports, ZIP/PDF/HTML exports, checkpoint backups.
Do not place long generic advice in AGENTS.md.
Do not duplicate linter/typechecker rules in prose.
Move repeatable procedures into workflows.
Move domain-specific reusable checks into skills.
Move deterministic checks into hooks/scripts.
```

### 2.6 Read/search first, write later

Default policy:

```text
Read-only inspection first.
Then plan.
Then implement exactly one approved slice.
```

Ask before:

```text
admin/elevation
destructive actions
process termination
system setting changes
migrations
external writes
cloud/production actions
publish/signing/installer changes
secret access
broad refactor
write-capable MCP actions
```

---

## 3. Repository / Workspace Layout

### 3.1 Important project template

Canonical template path:

```text
C:\Users\Администратор\Documents\antigravity\_templates\agy-project-base
```

Canonical project root:

```text
C:\Users\Администратор\Documents\antigravity\<ProjectName>
```

Canonical important project layout:

```text
<ProjectRoot>\
  .agents\
    agents.md
    hooks.json
    hooks\
      agy_checkpoint.ps1
      guard_preflight.ps1
      guard_context_budget.ps1
      guard_offline_local_only.ps1
    rules\
      00-project-rules.md
      10-pipeline-rules.md
      20-safety-boundaries.md
      30-verification-gates.md
      40-mcp-tooling.md
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
      project-domain-accuracy\
        SKILL.md
      project-review-gate\
        SKILL.md
      <project-specific-skill>\
        SKILL.md

  .agy\
    PHASE_STATUS.json
    AGENT_STATE.md
    RECOVERY_PROMPT.md
    MCP_PROFILE.md
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

  AGENTS.md
  .gitignore
  .cbmignore
```

### 3.2 What to commit

Commit:

```text
.agents/workflows/
.agents/rules/
.agents/skills/          if project-specific and useful
AGENTS.md
docs/
source code
tests
package/config files
```

Do not commit:

```text
.agy/checkpoints/
.agy/LATEST_CHECKPOINT.*
.agy/LATEST_UNTRACKED.*
.pipeline_*_backup/
.codebase-memory/
generated ZIP/PDF/HTML unless intentionally tracked
.env
secrets
```

---

## 4. Project Lifecycle

### 4.1 Stage 0 — Raw idea capture

Input may be vague:

```text
"Хочу приложение, которое анализирует H10 логи."
```

ChatGPT Project must transform it into:

```text
Project goal
Users
Scope
Non-goals
Target environment
Data sources
Privacy/security constraints
Architecture assumptions
MVP criteria
Verification gates
Open questions
Agent execution prompts
```

### 4.2 Stage 1 — Agent Task Pack

ChatGPT Project outputs a minimal Agent Task Pack:

```text
docs/PROJECT.md
docs/SPEC.md
docs/ARCHITECTURE.md
docs/DATA_SOURCES.md
docs/IMPLEMENTATION_PLAN.md
docs/VERIFICATION_PLAN.md
docs/RISKS_AND_ASSUMPTIONS.md
docs/EXECUTION_PROMPTS.md
AGENTS.md
project-specific rules/skills if needed
```

Do not produce a giant monolithic prompt. The goal is executable precision, not volume.

### 4.3 Stage 2 — Create project workspace

Canonical command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\Documents\antigravity\_templates\New-AgyProject.ps1" `
  -Name "<ProjectName>"
```

Open exactly:

```text
C:\Users\Администратор\Documents\antigravity\<ProjectName>
```

in Antigravity.

### 4.4 Stage 3 — Specification-only run

Command:

```text
/specdoc
```

Purpose:

```text
Write/repair docs only.
No source code.
No scaffolding.
No dependency install.
No tests/publish.
```

Outputs:

```text
docs/PROJECT.md
docs/SPEC.md
docs/ARCHITECTURE.md
docs/DATA_SOURCES.md
docs/RISKS_AND_ASSUMPTIONS.md
docs/EXECUTION_PROMPTS.md
.agy state files
```

### 4.5 Stage 4 — Plan-only run

Command:

```text
/planonly
```

Purpose:

```text
Create small verifiable phases.
Initialize .agy/PHASE_STATUS.json.
No source code.
No scaffolding.
```

Every phase must include:

```text
id
goal
risk level
likely files/components
checks
acceptance criteria
stop conditions
rollback/checkpoint notes
```

Default:

```json
{
  "current_policy": "one_phase_only",
  "batch_allowed": false
}
```

### 4.6 Stage 5 — Audit before implementation

Command:

```text
/auditphase
```

Purpose:

```text
Check whether docs, plans, state, tests, and current code are consistent.
No feature work.
```

Use especially when:

```text
The agent already generated code.
State files say "done" but docs disagree.
A previous session crossed phase boundaries.
Project was imported from another workspace.
```

### 4.7 Stage 6 — Probe phase

Command:

```text
/probephase
```

Use for:

```text
OS APIs
hardware behavior
filesystem/network permissions
database/storage assumptions
external API behavior
large-file parsing
security-sensitive data flow
```

Do not build full product during probe.

### 4.8 Stage 7 — One implementation phase

Command:

```text
/nextphase
```

It must:

```text
Read .agy/PHASE_STATUS.json
Select exactly one approved next phase
Run preflight
Implement only that phase
Verify
Review
Fix only blocking issues
Update .agy
Checkpoint
Stop
```

### 4.9 Stage 8 — Batch mode

Command:

```text
/phasebatch
```

Allowed only if:

```json
"batch_allowed": true
```

Use only for:

```text
Low-risk, well-tested, non-security, non-data-loss phases.
```

Maximum:

```text
2 low-risk phases per batch.
```

Never use batch for:

```text
new data source
security/privacy changes
ZIP/export rules
medical wording
database migration
filesystem write semantics
system APIs
large refactors
```

### 4.10 Stage 9 — Visual QA

Command:

```text
/visualqa
```

Use for browser UI projects.

Checks:

```text
App starts
No console errors
No unexpected external network requests
Local-only behavior
Dark theme readability
Charts not clipped
Dialogs/selects keyboard accessible
No raw i18n keys
Screenshots or recorded artifacts produced
```

### 4.11 Stage 10 — Security audit

Command:

```text
/securityaudit
```

Checks:

```text
No telemetry/cloud
Localhost/loopback only if required
No source-log mutation
No secrets in commits
No path traversal in ZIP
No unsafe markdown/HTML execution
No diagnostic medical claims
No write-capable MCP actions without approval
```

### 4.12 Stage 11 — Ship check

Command:

```text
/shipcheck
```

No features. Release readiness only.

A project is shippable only when:

```text
MVP criteria pass
Build/test evidence exists
Visual QA passed if UI
Security/privacy audit passed if relevant
Known risks documented
No false "done" status
Rollback notes exist
```

---

## 5. Workflows

### 5.1 Canonical workflows

```text
/specdoc
/planonly
/auditphase
/probephase
/nextphase
/phasebatch
/fixcritical
/landing
/visualqa
/securityaudit
/shipcheck
/lessons
/codebase-map
```

### 5.2 Workflow authoring rules

Each workflow file must:

```text
Live in .agents/workflows/
Have valid YAML frontmatter
Have one clear description
Declare allowed writes
Declare forbidden writes
Declare stop conditions
Declare output contract
End with "stop" when applicable
```

Do not put non-workflow notes in `.agents/workflows/`.

### 5.3 `/codebase-map`

Use after Codebase Memory MCP is configured.

Purpose:

```text
Refresh/index codebase graph
Produce architecture map
Identify module dependencies
Find source-log read/write paths
Find report/LLM Pack dependency paths
No feature work
```

Typical sequence for mature projects:

```text
/codebase-map
/auditphase
```

---

## 6. Hooks

### 6.1 Hook purpose

Hooks are deterministic guardrails and checkpoint machinery, not prompts.

Canonical hooks:

```text
.agents/hooks/agy_checkpoint.ps1
.agents/hooks/guard_preflight.ps1
.agents/hooks/guard_context_budget.ps1
.agents/hooks/guard_offline_local_only.ps1
.agents/hooks.json
```

### 6.2 `agy_checkpoint.ps1`

Purpose:

```text
Save git status
Save diff stat
Save binary patch
Save untracked list
Update .agy/LATEST_CHECKPOINT.*
Return JSON stdout
Never block on stdin during manual PowerShell runs
```

Important implementation rule:

```powershell
if ([Console]::IsInputRedirected) {
  $HookInput = [Console]::In.ReadToEnd()
}
```

Manual check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\agy_checkpoint.ps1" -Event manual
```

Expected:

```json
{}
```

### 6.3 `guard_preflight.ps1`

Purpose:

```text
Ensure required pipeline files exist.
```

Manual check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\guard_preflight.ps1"
```

Expected:

```text
Pipeline preflight OK.
```

### 6.4 `guard_context_budget.ps1`

Purpose:

```text
Ensure generated/runtime folders are ignored.
```

It must cover:

```text
node_modules/
dist/
.git/
.agy/checkpoints/
.pipeline_*_backup/
.codebase-memory/
coverage/
```

### 6.5 `guard_offline_local_only.ps1`

Purpose:

```text
Detect likely external URLs or telemetry SDKs in source.
```

It is diagnostic by default.

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\guard_offline_local_only.ps1"
```

Strict mode only after audit tuning:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\guard_offline_local_only.ps1" -Strict
```

Expected false-positive allowances:

```text
fetch( in frontend local API client
http://www.w3.org/2000/svg namespace
https://example.com placeholder in sanitizer tests
```

---

## 7. Skills

### 7.1 Generic project skills

```text
project-domain-accuracy
project-review-gate
```

Use for:

```text
Domain semantics
Measured vs estimated vs inferred distinctions
Requirement coverage review
Security/privacy/scope review
```

### 7.2 H10-specific project skills

```text
h10-medical-language-safety
h10-llm-pack-security
h10-ingestion-readonly-guard
```

Use only in H10 Athlete Cardio Lab or similar health-data projects.

#### h10-medical-language-safety

Prevents:

```text
diagnostic claims
clinical claims
"normal/abnormal" conclusions
"arrhythmia detected"
false reassurance
```

Enforces:

```text
personal baseline
candidate event
informational wording
non-diagnostic disclaimers
```

#### h10-llm-pack-security

Enforces:

```text
flat ZIP layout
no path traversal
redaction
size budgets
manifest/checksums
safe markdown import
no full raw logs by default
```

#### h10-ingestion-readonly-guard

Enforces:

```text
Z:\Polar Logs is read-only
source logs are never renamed/moved/deleted/edited
app cache/database/export folders are the only writable locations
large ECG/ACC files are streamed or windowed
```

### 7.3 Skill policy

Do not install large broad skill packs into every project without need.

Rule:

```text
Global skills = universal behavior.
Project skills = domain-specific risk controls.
Workflow = repeated sequence.
Hook = deterministic enforcement.
```

---

## 8. MCP Policy

### 8.1 MCP is not autopilot

MCP servers are available tools. The agent may or may not use them automatically. For important work, explicitly instruct usage.

### 8.2 Current MCP config pattern

Global config:

```text
C:\Users\Администратор\.gemini\config\mcp_config.json
```

Expected servers:

```json
{
  "mcpServers": {
    "chrome-devtools-mcp": {
      "command": "C:\\Users\\Администратор\\AppData\\Roaming\\npm\\chrome-devtools-mcp.cmd",
      "args": []
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

### 8.3 Context7 usage

Use when prompt contains:

```text
Use Context7/current official docs for version-sensitive APIs.
```

### 8.4 Codebase Memory usage

Use explicitly:

```text
Use Codebase Memory MCP to index this project, respecting `.cbmignore`.

Do not implement features.

Use it only for structural questions:
- architecture overview;
- impact analysis;
- call graph;
- routes and report/LLM Pack dependencies;
- source-log read/write risk paths.
```

### 8.5 Browser/Chrome DevTools usage

Use inside `/visualqa`.

### 8.6 GitHub MCP usage

Read-only only, after remote repo exists.

### 8.7 Docker Gateway usage

Optional only for many MCP servers/profiles.

---

## 9. Current Known State: H10 Athlete Cardio Lab

Project path:

```text
C:\Users\Администратор\Documents\antigravity\H10 Athlete Cardio Lab
```

Observed project type:

```text
TypeScript / React / Vite / Node
Local-first health-data analysis
Polar H10 raw logs
Reports / LLM Pack / UI
```

Current pipeline state should be:

```json
{
  "project_status": "needs_independent_audit",
  "next_required_command": "/auditphase",
  "batch_allowed": false
}
```

Current safe sequence:

```text
/codebase-map   if Codebase Memory is configured
/auditphase
/fixcritical    only if blockers exist
/visualqa
/securityaudit
/shipcheck
```

Do not run:

```text
/phasebatch
/build auto
feature prompts
```

until the independent audit passes.

---

## 10. New Project Decision Matrix

### 10.1 Tiny experiment

Use:

```text
/specdoc optional
/nextphase or direct small prompt
No Codebase Memory
No project-specific skills unless needed
```

### 10.2 Important product/tooling project

Use full template:

```text
New-AgyProject
/specdoc
/planonly
/auditphase
/probephase if needed
/nextphase loop
/visualqa if UI
/securityaudit if data/security
/shipcheck
```

### 10.3 Hardware/system/API/database/security project

Mandatory:

```text
/probephase before implementation
No /phasebatch until probes pass
No /build auto
Extra safety rules
```

### 10.4 Mature large codebase

Add:

```text
.cbmignore
Codebase Memory MCP
/codebase-map before audit/refactor
```

### 10.5 Browser UI project

Add:

```text
/visualqa
Chrome DevTools MCP / Browser Subagent
screenshot evidence
console/network checks
```

### 10.6 Health/medical-like data project

Add:

```text
medical-language-safety skill
privacy redaction skill
no diagnostic wording
no raw logs by default
```

---

## 11. Version and Environment Registry

Every serious project should include:

```text
docs/ENVIRONMENT.md
```

or append to `docs/PROJECT.md`:

```text
Antigravity version:
Codex version:
agent-skills plugin version:
Node version:
npm version:
Package manager:
Codebase Memory version:
Chrome DevTools MCP command:
Context7 MCP config:
Git version:
OS version:
Project path:
```

Commands:

```powershell
agy --version
agy plugin list
node --version
npm --version
git --version
codebase-memory-mcp --version
Get-Content "$env:USERPROFILE\.gemini\config\mcp_config.json" -Raw
```

---

## 12. Failure Modes and Countermeasures

### 12.1 Agent implemented during planning

Countermeasure:

```text
Use /specdoc and /planonly with allowed-write lists.
No generic /planning for high-risk projects.
```

### 12.2 Agent crossed phase boundaries

Countermeasure:

```text
Use .agy/PHASE_STATUS.json
Use /nextphase one-phase workflow
Disable /phasebatch until explicit unlock
```

### 12.3 Agent claimed ready while docs disagreed

Countermeasure:

```text
Set project_status=needs_independent_audit
Run /auditphase
Run /shipcheck only after audit consistency
```

### 12.4 Hook hung in manual PowerShell

Countermeasure:

```text
Never call Console.In.ReadToEnd() unless [Console]::IsInputRedirected.
```

### 12.5 Offline guard false positives

Countermeasure:

```text
Scan src/package only by default.
Exclude .agents, docs, backups, dist, node_modules.
Run non-strict before strict.
```

### 12.6 MCP overuse / tool bloat

Countermeasure:

```text
Use smallest MCP surface.
Use explicit MCP route in prompt.
Do not enable duplicate direct + gateway routes.
Record MCP usage in .agy/MCP_PROFILE.md.
```

---

## 13. Standard Prompts

### 13.1 Raw idea → Agent Task Pack

```text
Преврати мою raw-идею в Agent Task Pack для Antigravity/Codex.

Не начинай реализацию.

Выдай:
1. Краткий вывод.
2. Критичные вопросы.
3. Assumptions.
4. PROJECT.md.
5. SPEC.md.
6. ARCHITECTURE.md.
7. DATA_SOURCES.md если есть данные/API.
8. IMPLEMENTATION_PLAN.md.
9. VERIFICATION_PLAN.md.
10. RISKS_AND_ASSUMPTIONS.md.
11. AGENTS.md.
12. Execution prompts:
    - /specdoc
    - /planonly
    - /auditphase
    - /probephase
    - /nextphase
    - /landing
    - /shipcheck
13. Риски и локальные проверки.

Используй свежие официальные docs для изменчивых API/tool behavior.
Разделяй verified facts, assumptions, risks, unknowns.
```

### 13.2 Codebase Memory bootstrap prompt

```text
Use Codebase Memory MCP to index this project, respecting `.cbmignore`.

Do not implement features.

Use Codebase Memory only for structural questions:
- architecture overview;
- impact analysis;
- call graph;
- routes and report/LLM Pack dependencies;
- source-log read/write risk paths.

Do not scan:
- node_modules
- dist
- .git
- .agy/checkpoints
- .pipeline_patch_backup
- .pipeline_sync_backup

After indexing, stop with a concise codebase map and recommended next command.
```

### 13.3 Audit prompt

```text
/auditphase

Audit the current workspace against docs, tests, state files, safety rules, and MCP/tooling policy.

Do not implement features.

Use Codebase Memory only for structural questions if available.
Use Context7 only for version-sensitive API behavior.
Update `.agy/PHASE_STATUS.json`, `.agy/AGENT_STATE.md`, and `.agy/RECOVERY_PROMPT.md`.

Stop after the audit report.
```

---

## 14. Governance and Versioning

### 14.1 Document versioning

This document should be stored as:

```text
docs/AGENTIC_PIPELINE_PLAYBOOK.md
```

Recommended version format:

```text
MAJOR.MINOR.PATCH
```

Update rules:

```text
MAJOR: pipeline architecture change
MINOR: new workflow/hook/skill/MCP policy
PATCH: wording, command fixes, false-positive tuning
```

### 14.2 Change log template

```md
## Changelog

### v1.0.0 — 2026-06-22
- Established ChatGPT Project → Antigravity → Codex pipeline.
- Added strict workflows.
- Added .agy phase ledger.
- Added checkpoint/preflight/offline/context hooks.
- Added Codebase Memory policy.
- Added H10-specific skills.
```

### 14.3 Deep Research model update contract

When another model audits this playbook, ask it to:

```text
1. Verify all tool docs and current versions.
2. Identify obsolete assumptions.
3. Find pipeline gaps and failure modes.
4. Propose minimal changes, not broad rewrites.
5. Preserve PowerShell-only local mutation.
6. Preserve phase gates and evidence requirements.
7. Avoid context bloat and skill leakage.
8. Return a versioned diff proposal:
   - Proposed version bump
   - Files affected
   - Rationale
   - Exact PowerShell patch commands
   - Risks
   - Rollback
```

---

## 15. Non-Negotiables

```text
Never trust "done" without evidence.
Never let planning write source code.
Never let one phase become an epic.
Never run /phasebatch while batch_allowed=false.
Never use write-capable MCP without explicit approval.
Never scan node_modules/dist/generated artifacts as project context.
Never persist secrets or raw private logs in agent state.
Never ship after state/docs/test mismatch.
Always update .agy state after substantial work.
Always stop after one phase unless explicitly permitted.
```

---

## 16. Immediate Next Step for Current H10 Project

If Codebase Memory MCP is configured:

```text
/codebase-map
/auditphase
```

If Codebase Memory MCP is not yet visible in Antigravity:

```text
/auditphase
```

Do not start feature work until:

```text
auditphase passes
visualqa passes
securityaudit passes
shipcheck passes
```