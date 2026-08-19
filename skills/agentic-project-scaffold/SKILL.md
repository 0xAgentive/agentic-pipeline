---
name: agentic-project-scaffold
description: >-
  Automatically scaffolds, initializes, and configures brand-new repositories or adopts
  existing projects into the Agentic Pipeline v1.2.27 ecosystem. Sets up .agents/ rules,
  workflows (/nextphase, /auditphase, /fixcritical), .agy/ control plane, registers project
  in Companion Action Bridge, configures Git, and produces an initial Companion Context Pack
  for ChatGPT/Claude with zero manual setup. Trigger with /new-project, /adopt-project,
  or phrases like "создай новый проект под пайплайном", "подключи существующий проект к пайплайну".
---

# Agentic Project Scaffold — Global Skill

This skill automates the creation of a brand-new software project configured for **Agentic Pipeline v1.2.27** from scratch (requiring ONLY the project name from the user), or onboards (*adopts*) any existing project into the ecosystem without breaking existing code.

---

## When to Activate

Activate this skill when:
- The user requests: *"создай новый проект под пайплайном: <Имя>"*, *"инициализируй проект для пайплайна"*, *"подключи существующий проект к пайплайну"*, *"сделай проект с нуля под agentic pipeline"*.
- The user invokes slash commands: `/new-project <Name>`, `/adopt-project <Path>`, `/agentic-init <Name>`.

---

## What the Skill Performs Automatically

When given just a project name (e.g. `/new-project CardioTracker`):

1. **Creates Target Directory**:
   `C:\Users\Администратор\Documents\antigravity\<ProjectName>`
2. **Initializes Git Repository**:
   Runs `git init` and sets `main` branch.
3. **Installs Agentic Pipeline v1.2.27 Runtime**:
   - Deploys `.agents/` (all workflows: `/nextphase`, `/auditphase`, `/fixcritical`, `/fastpatch`, `/shipcheck`, rules, project skills, and runtime hooks).
   - Deploys `.agy/` (control plane manifests, `WORK_ITEM.json`, `STAGE_FIREWALL.json`, `FINDINGS.json`, `INSTALLATION_MANIFEST.json`).
4. **Action Bridge Registration**:
   - Generates a unique 64-hex cryptographic capability token (`ACTION_BRIDGE_CAPABILITY.json`).
   - Automatically registers the project in `C:\Users\Администратор\.agentic-pipeline\project-registry.json` so that downloaded Action Packets from ChatGPT / Claude are routed to this project without manual intervention.
5. **Project Scaffolding**:
   - Creates `src/`, `tests/`, `scripts/`, `docs/`.
   - Generates project-specific `AGENTS.md` and `README.md`.
6. **Automatic Companion Context Pack Generation**:
   - Triggers `companion-project-context-pack` to build the initial ZIP archive (`<PROJECT>_COMPREHENSIVE_COMPANION_PACK.zip`) for ChatGPT!
7. **Initial Git Commit**:
   Creates the initial baseline commit.

---

## One-Command Execution for the Agent

To execute this skill, run the bundled PowerShell script:

```powershell
& pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Администратор\.gemini\config\skills\agentic-project-scaffold\scripts\New-AgenticProject.ps1" -ProjectName "<ProjectName>" -Stack "Generic" -Apply
```

For adopting an existing project:

```powershell
& pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Администратор\.gemini\config\skills\agentic-project-scaffold\scripts\New-AgenticProject.ps1" -ProjectName "<ProjectName>" -TargetRoot "C:\path\to\existing\repo" -Mode "Adopt" -Apply
```

---

## Owner Output Contract

Use the 4 plain-language Russian sections:
1. `## Что происходит`
2. `## Что уже сделано`
3. `## Что будет дальше`
4. `## Нужно ли что-то от владельца`

And report primary artifacts in `АРТЕФАКТЫ`:
```text
АРТЕФАКТЫ

- Каталог созданного проекта — <native absolute path to project>
- Начальный контекстный ZIP-пакет для Компаньона — <native absolute path to .zip>
```
