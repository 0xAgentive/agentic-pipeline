# Agentic Development Pipeline Playbook v1.2.0

Version: `1.2.0`
Codename: `Product Evidence Control Plane`
Status: `major framework specification`
Primary runtime: `Google Antigravity`
Active models: `Gemini Flash 3.5 Medium/High`
Codex status: `optional compatibility layer, not active runtime by default`

## 1. Executive summary

v1.2.0 upgrades the pipeline from a Markdown-heavy phase process into a measurable product-evidence control plane.

The framework must prevent observed failure modes:

- the agent writes `SHIP` while requirements changed;
- reports contradict quality gates;
- artifacts are missing or only visible in IDE internals;
- screenshots/walkthroughs are not preserved;
- UI blockers are treated as cosmetic;
- generated reports leak raw enum keys, paths, device IDs, or forbidden wording;
- a model-written evidence note is treated as verification;
- a large playbook is repeatedly loaded into hot context;
- MCP/tool surface expands without approval.

## 2. Non-negotiable principles

### 2.1 Evidence beats claims

Model prose is not verification.

Valid evidence is:

- exit code 0 from deterministic checks;
- git diff;
- test output;
- parser/build/lint output;
- screenshot or browser artifact for UI;
- ZIP/PDF/HTML/CSV artifact manifest;
- SHA-256 and file size;
- grep/static scan output;
- semantic/domain tests where applicable.

### 2.2 Product contract beats stale plans

If the user changes product scope, the pipeline must update requirements, acceptance criteria, artifacts, tests and state before further implementation.

Unresolved requirement deltas block `/shipcheck`.

### 2.3 Artifacts are first-class

Material audit/shipcheck/report/visual phases must write evidence artifacts to disk, not only to chat.

### 2.4 Hot runtime must be small

The full playbook is a reference. Normal workflows must not require reading the full playbook.

### 2.5 Read-only parallelism only

Parallel lanes are allowed only for read-only audits. Write-capable implementation remains single executor and phase-gated.

## 3. v1.2 source layout

```text
runtime-src/
  core.yml
  workflows/*.yml
  rules/*.yml
  hooks.yml
  skills.yml
  tool-profiles/*.yml

templates/agy-project-base/
  .agents/
    AGENTS.md
    workflows/*.md
    rules/*.md
    skills/*/SKILL.md
    hooks.json
    hooks.sample.json
    hooks/*.ps1
    tool-profiles/*.json
  .agy/
    PHASE_STATUS.json
    PHASE_STATUS.schema.json
    PRODUCT_CONTRACT.json
    REQUIREMENTS_DELTA.md
    REQUIREMENTS_DELTA.ndjson
    ARTIFACT_INDEX.ndjson
    evidence.ndjson
    RUN_METRICS.ndjson
    APPROVALS.json
    AGENT_STATE.md
    RECOVERY_PROMPT.md
  .artifacts/
    README.md

scripts/
  runtime/
  validate/
  artifacts/
  state/
  evals/
  package/
  migration/

evals/golden/
schemas/
docs/
```

## 4. Required state files

### `.agy/PHASE_STATUS.json`

Minimum fields:

```json
{
  "schema_version": "1.2.0",
  "project_name": "",
  "current_phase": "/auditphase",
  "next_required_command": "/nextphase",
  "commands_allowed_now": [],
  "phase_lock": true,
  "batch_allowed": false,
  "risk_level": "low|medium|high|critical",
  "dirty_state": "clean|dirty|unknown",
  "hook_mode": "manual|advisory|enforcing",
  "last_verified_at_utc": null,
  "open_blockers": [],
  "unresolved_requirement_deltas": 0,
  "required_artifacts_missing": 0
}
```

### `.agy/PRODUCT_CONTRACT.json`

Defines current product goal, modes, required gates, forbidden artifacts/claims, sensitive data boundaries and shipcheck blockers.

### `.agy/REQUIREMENTS_DELTA.ndjson`

Each user-driven scope change creates one entry:

```json
{
  "ts_utc": "2026-07-08T00:00:00Z",
  "run_id": "...",
  "old_goal": "...",
  "new_goal": "...",
  "affected_workflows": [],
  "affected_artifacts": [],
  "tests_required": [],
  "blocks_shipcheck": true,
  "status": "open"
}
```

### `.agy/evidence.ndjson`

Machine evidence source of truth. Markdown evidence is a human-readable view, not gate input.

### `.agy/RUN_METRICS.ndjson`

Records command, phase, duration, files read/changed, checks, artifacts, tool/MCP use, model/thinking level when available.

### `.agy/ARTIFACT_INDEX.ndjson`

Indexes artifacts with path, kind, size, SHA-256, creator command, phase id and required_for_shipcheck flag.

## 5. Artifact Delivery Contract

Every material auditphase, reportqa, visualqa, shipcheck and artifact-producing nextphase must produce an evidence archive.

Default path:

```text
.artifacts/<phase_id>_<run_id>/<phase_id>_evidence.zip
```

Minimum archive contents:

```text
00_AUDIT_SUMMARY.md
01_COMMAND_RESULTS.md
02_CHANGED_FILES.md
03_ARTIFACT_FILE_LISTS.md
04_FORBIDDEN_TEXT_SCAN.md
05_MANUAL_VERIFICATION.md
06_RISKS_AND_UNVERIFIED.md
07_NEXT_STEP.md
ARTIFACT_MANIFEST.json
task.md
walkthrough.md
```

Final response after such a phase must print:

```text
Evidence ZIP absolute path:
Evidence ZIP relative path:
Size bytes:
SHA-256:
Contents:
```

If required artifacts are missing, `/auditphase` and `/shipcheck` must fail.

## 6. Workflow contracts

Every workflow has a contract:

```yaml
name: nextphase
mode: write
allowed_reads: []
allowed_writes: []
forbidden_writes: []
required_gates: []
required_artifacts: []
tool_profile: local-only
stop_conditions: []
next_state_rule: ""
```

Required workflows:

```text
/triage
/specdoc
/planonly
/probephase
/auditphase
/nextphase
/fastpatch
/fixcritical
/visualqa
/reportqa
/securityaudit
/artifactaudit
/parallel-audit
/landing
/lessons
/githubprepare
/githubsync
/shipcheck
```

## 7. Gate policy

### `/triage`

Read-only. JSON only. Recommends next command. Never edits. Never marks ready.

### `/fastpatch`

Requires preflight plus post-diff gate. Must inspect staged, unstaged and untracked files. Must block backend imports, network/storage APIs, dangerous HTML, secrets, broad diffs and files outside allowlist.

### `/visualqa`

Required for browser/UI projects. Must capture screenshot/walkthrough/console evidence. Blocks raw i18n keys, unreadable dark dropdowns, clipped charts, browser alert/confirm and missing accessibility basics.

### `/reportqa`

Required for generated PDF/HTML/ZIP/CSV artifacts. Must unpack/scan generated artifacts for manifest, redaction, forbidden text, raw enum labels, unit consistency and required sections.

### `/securityaudit`

Read-only by default. Required for secrets, local data, MCP, exports, sanitizers, file systems and privacy boundaries.

### `/parallel-audit`

Read-only lanes only. Writes artifacts only. No source writes. One coordinator merge. Fixes happen later in single `/nextphase`.

### `/shipcheck`

Returns `SHIP` or `NO-SHIP`.

`SHIP` requires:

- valid PHASE_STATUS;
- no open blocking requirement deltas;
- required checks pass;
- required artifacts exist;
- evidence.ndjson valid;
- visual/report/security gates pass where applicable;
- rollback path exists;
- no critical unverified claims.

## 8. Skills

Use narrow skills for project-specific procedures:

```text
artifact-audit
requirement-drift-audit
release-evidence-packaging
visual-qa
report-qa
security-privacy-review
windows-powershell-hardening
github-publication
h10-medical-language-safety
h10-llm-pack-security
h10-source-ingestion-safety
```

Skills are loaded on demand. They must not duplicate the entire playbook.

## 9. Hooks

Hook modes:

```text
manual
advisory
enforcing
```

Production hooks are valid only if `hooks.json` wires them or the release explicitly labels them as manual scripts.

Required hook families:

```text
guard_preflight
guard_phase_transition
guard_context_budget
guard_worktree_scope
guard_reference_integrity
guard_evidence_required
guard_artifact_manifest
guard_visualqa_required
guard_reportqa_required
guard_tool_surface
guard_offline_local_only
guard_fastpatch_postdiff
agy_checkpoint
Test-HookContract
```

## 10. Tool/MCP profiles

Default tool surface is local/read-only.

No write-capable MCP without explicit approval. MCP output is not release truth. Codebase Memory remains optional/read-only/raw-data-safe and is not hot-path default.

Every workflow has a tool profile:

```json
{
  "workflow": "visualqa",
  "read_only": true,
  "allowed_mcp_servers": [],
  "max_active_tools": 8,
  "network": "none",
  "write_requires_approval": true
}
```

## 11. Validators

Required validators:

```text
Validate-All.ps1
Validate-ReferenceIntegrity.ps1
Validate-WorkflowContracts.ps1
Validate-StateMachine.ps1
Validate-HookContracts.ps1
Validate-Skills.ps1
Validate-ToolProfiles.ps1
Validate-ArtifactContract.ps1
Validate-RequirementDrift.ps1
Validate-ShipcheckEvidence.ps1
Validate-PackageNoArtifacts.ps1
Validate-CIParity.ps1
```

Validators must detect:

- missing references;
- stale generated runtime;
- invalid schemas;
- placeholder hooks;
- active-hooks claim mismatch;
- backup artifacts;
- raw local paths in package;
- SHIP without evidence;
- semantic tests required but missing;
- visual/report/security gate claims without artifacts.

## 12. Eval suite

Local regression harness, not cloud-only.

Golden evals:

```text
planonly_no_write
auditphase_no_feature_write
nextphase_one_phase_only
fastpatch_blocks_backend
fastpatch_sees_untracked
fastpatch_requires_postdiff
shipcheck_requires_evidence
visualqa_required_for_ui
reportqa_required_for_exports
securityaudit_required_for_sensitive_data
artifact_missing_blocks_audit
artifact_contradiction_blocks_shipcheck
requirements_delta_blocks_shipcheck
stale_phase_status_blocks_nextphase
```

## 13. Structured diagnostics reusable requirement

For mature local apps with data, the pipeline requires structured logs and diagnostic bundle contract.

Recommended categories:

```text
source
sync
parser
qc
analytics
report
llm_pack
ui
chart
security
```

Logs must redact secrets, device IDs, raw biometrics, local paths and personal notes unless explicitly allowed.

## 14. v1.2 phased implementation

P0 — Stabilization gate and baseline
P1 — Runtime source and compiler
P2 — Workflow contracts and state schemas
P3 — Evidence ledger and Artifact Delivery Contract
P4 — Product Contract and Requirement Drift Gate
P5 — Hard validator suite
P6 — Local eval suite
P7 — Skills and progressive disclosure
P8 — Hook modes and production hook contract
P9 — VisualQA / ReportQA / SecurityQA gates
P10 — Tool/MCP profiles and approvals
P11 — Metrics and observability
P12 — codebase-map-fast and CBM policy
P13 — read-only triage
P14 — read-only parallel audit
P15 — package builder, migration and rollback
P16 — final shipcheck v2 and release archive

## 15. Definition of Done

v1.2 is complete only if:

1. r4/r4b stabilization green.
2. Runtime compiles from runtime-src.
3. Hot workflows are self-contained.
4. Full playbook not required in normal hot path.
5. Product contract exists and validates.
6. Requirements delta blocks stale shipcheck.
7. Artifact manifests exist for material phases.
8. evidence.ndjson is source of truth.
9. RUN_METRICS.ndjson is created by smoke runs.
10. VisualQA gate has screenshot/console evidence.
11. ReportQA checks generated artifacts.
12. SecurityQA exists for sensitive/local-data projects.
13. Eval suite runs in CI.
14. Skills are narrow and lazy-loaded.
15. Every workflow has a tool profile.
16. MCP write capability requires approval.
17. `/triage` is read-only JSON.
18. `/parallel-audit` is read-only only.
19. Release archive verifies after extraction.
20. Migration and rollback docs exist.
21. `/shipcheck` returns `NO-SHIP` on any critical missing evidence.

## 16. Non-goals

Do not include by default:

- write-capable autonomous multi-agent implementation;
- automatic cloud deploy;
- automatic GitHub publish;
- mandatory API executor;
- mandatory prompt-cache optimization;
- mandatory Codebase Memory, Sourcegraph, or MCP;
- silent durable rule mutation from `/lessons`;
- model-only verification;
- provider lock-in for evals/metrics.
