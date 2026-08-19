---
name: companion-project-context-pack
description: >-
  Extracts, packages, and formats an exhaustive architectural context pack of any repository
  for external LLM companions (ChatGPT, GPT-5, Claude) without heavy data or binary blobs.
  Generates comprehensive project orientation guides, codebase maps, mathematical/data algorithm
  contracts, system prompts, validated Agentic Action Packets, and copies the entire pure
  architectural source tree (src, scripts, schemas, docs, tests, .agy, .agents) into a compact,
  self-contained ZIP archive. Use when the user asks to create an initial context pack,
  export project for companion/ChatGPT, or when invoked via `/companion-pack` or `/companion-context`.
---

# Companion Project Context Pack — Global Skill

This skill creates an exhaustive, self-contained, privacy-safe, and pure architectural context package for any repository. The resulting package allows a completely fresh external LLM (ChatGPT / GPT-5 / Claude) to understand the entire codebase, architecture, data schemas, mathematical algorithms, and state, and immediately formulate valid Agentic Action Packets for autonomous execution in Antigravity.

---

## When to Activate

Activate this skill when:
- The user requests: *"сформировать контекст для компаньона"*, *"создать первоначальный пакет проекта для ChatGPT / GPT-5 / Claude"*, *"экспортировать проект для внешнего ИИ"*, *"собрать контекстный архив кодовой базы"*.
- The user invokes slash commands: `/companion-pack`, `/companion-context`, `/companion-bootstrap`.
- Starting collaboration with a new LLM companion on an existing repository where the model needs complete codebase awareness without downloading gigabytes of logs, caches, or `node_modules`.

---

## What the Skill Generates

A self-contained folder and companion ZIP archive:
`C:\Users\Администратор\Documents\antigravity\companion-packs\<PROJECT_NAME>_COMPREHENSIVE_COMPANION_PACK.zip`

Containing:
1. `00_COMPANION_MASTER_GUIDE.md`:
   - Executive orientation for the LLM.
   - Project passport, stack, active branch, HEAD commit, operating mode, rules of engagement (`owner_interaction_policy: "hard_stop_only"`, `scope_binding: "executor_discovery"`).
2. `01_CODEBASE_INDEX_AND_ARCHITECTURE_MAP.md`:
   - Annotated index of all source files, line counts, modules, controllers, components, and data paths.
3. `02_DATA_FORMATS_AND_ALGORITHMS.md`:
   - Concrete mathematical formulas, data schemas, sensor/signal formats, and domain contracts.
4. `03_COMPANION_SYSTEM_PROMPT.md`:
   - Copy-pasteable system prompt specifically tuned for the LLM Companion session.
5. `05_ACTION_PACKET_EXAMPLES/`:
   - Validated JSON Action Packets (`/auditphase`, `/nextphase`, `/fastpatch`) compliant with schema 1.2.9 and ecosystem 1.2.27.
6. `<project-slug>-source/`:
   - **Complete, unmodified pure architectural source code**:
     - `src/**` (All backend, frontend, shared code).
     - `scripts/**` (All Python, Shell, PowerShell scripts).
     - `schemas/**` (All JSON / Protocol schemas).
     - `docs/**` (All methodology, architecture, and protocol documents).
     - `tests/**` (All unit, integration, and e2e tests).
     - `.agents/**` (All workflow definitions).
     - `.agy/**` (Authoritative state manifests: `WORK_ITEM.json`, `PHASE_STATUS.json`, `STAGE_FIREWALL.json`, `FINDINGS.json`, `RUN_RESULT.json`, `VERIFICATION_RECEIPT.json`, `EVIDENCE_LOG.md`).
     - Root project configurations (`package.json`, `tsconfig.json`, `pyproject.toml`, `Cargo.toml`, `AGENTS.md`, `README.md`).

---

## Exclusion Rules (Strict Hygiene)

The following paths are **STRICTLY EXCLUDED** to keep the package lightweight (< 5–25 MB) and privacy-safe:
- `node_modules/**`, `.venv*/**`, `.python*/**`
- `data/**` (raw sensor dumps, empirical training datasets, video/audio recordings)
- `.git/**`
- `dist/**`, `build/**`, `out/**`, `coverage/**`
- `.artifacts/**` (heavy installer executables, pre-built binary releases)
- Binary extensions: `*.exe`, `*.zip`, `*.tar`, `*.gz`, `*.db`, `*.sqlite`, `*.pyc`, `*.iso`
- Cache and scratch folders: `__pycache__`, `scratch/**`, `.agy/checkpoints/**`

---

## Step-by-Step Execution Workflow

### Step 1: Discover Project & State
1. Detect repository root, Git branch, HEAD commit, origin remote.
2. Read project manifests (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`).
3. Check for `.agy/` control plane state (`WORK_ITEM.json`, `PHASE_STATUS.json`, `ACTION_BRIDGE_CAPABILITY.json`).

### Step 2: Automated Script Invocation
Execute the bundled PowerShell helper script:

```powershell
& pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Администратор\.gemini\config\skills\companion-project-context-pack\scripts\New-CompanionProjectContextPack.ps1" -ProjectRoot "<TargetProjectDirectory>" -OutputDirectory "C:\Users\Администратор\Documents\antigravity\companion-packs" -EcosystemVersion "1.2.27"
```

### Step 3: Validate Action Packet Schemas
If the target project has `.agy/` or `action-packet.cjs`:
Run the schema validator against generated sample packets in `05_ACTION_PACKET_EXAMPLES/` to ensure 100% schema compliance.

### Step 4: Verify ZIP Integrity & Deliver
1. Check that the ZIP archive size is within limits (typically 500 KB – 5 MB).
2. Report the result to the owner using the compact Russian format (`АРТЕФАКТЫ`).

---

## Owner Output Contract

Use the 4 plain-language Russian sections:
1. `## Что происходит`
2. `## Что уже сделано`
3. `## Что будет дальше`
4. `## Нужно ли что-то от владельца`

And end with the compact `АРТЕФАКТЫ` section (at most 3 primary artifacts, complete native absolute paths, no Markdown file links):

```text
АРТЕФАКТЫ

- Полный контекстный ZIP-пакет проекта для Компаньона — <native absolute path to .zip>
- Руководство архитектора проекта для Компаньона — <native absolute path to 00_COMPANION_MASTER_GUIDE.md>
- Карта кодовой базы и архитектуры — <native absolute path to 01_CODEBASE_INDEX_AND_ARCHITECTURE_MAP.md>
```
