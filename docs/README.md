# Documentation Map

Welcome to the Agentic Development Pipeline documentation directory. This folder is organized by topic to make navigation simple for both human developers and agentic AI partners.

## Directory Structure

```text
docs/
├── [guides/]          # Step-by-step instructions for setup and operations
├── [concepts/]        # Core architectural and governance designs
├── [reference/]       # Syntax, version history, and command cheat sheets
├── [maintainers/]     # Templates, checklists, and pipeline design notes
└── [archive/]         # Historical baseline documents (for reference only)
```

---

## 1. Entry Point Documents (Root `docs/`)

These files are located in the root of `docs/` for compatibility with validators and quick-access:

*   [START_HERE.en.md](START_HERE.en.md) / [START_HERE.ru.md](START_HERE.ru.md) — The recommended starting guide and command checklist.
*   [AGENTIC_PIPELINE_PLAYBOOK.md](AGENTIC_PIPELINE_PLAYBOOK.md) — Canonical playbook specifying current rules and scoping constraints.
*   [GITHUB_PUBLICATION.md](GITHUB_PUBLICATION.md) — Safety procedures and command usage for GitHub publishing.
*   [AUDIT_CHECKLIST.md](AUDIT_CHECKLIST.md) — Hard checklist for package and repository validation.
*   [PIPELINE_VERSION_MATRIX.md](PIPELINE_VERSION_MATRIX.md) — Active version specifications and future roadmaps.
*   [CONTEXT_SPLIT.en.md](CONTEXT_SPLIT.en.md) / [CONTEXT_SPLIT.ru.md](CONTEXT_SPLIT.ru.md) — Architecture of context splitting.
*   [COMPANION_UPDATE_GUIDE.en.md](COMPANION_UPDATE_GUIDE.en.md) / [COMPANION_UPDATE_GUIDE.ru.md](COMPANION_UPDATE_GUIDE.ru.md) — Upgrading companion configuration.

---

## 2. Directories

### 📂 [Guides](guides/)
Step-by-step developer guides:
*   [NEW_PROJECT_GUIDE.en.md](guides/NEW_PROJECT_GUIDE.en.md) / [NEW_PROJECT_GUIDE.ru.md](guides/NEW_PROJECT_GUIDE.ru.md) — Initializing new workspaces.
*   [EXISTING_PROJECT_GUIDE.en.md](guides/EXISTING_PROJECT_GUIDE.en.md) / [EXISTING_PROJECT_GUIDE.ru.md](guides/EXISTING_PROJECT_GUIDE.ru.md) — Retrofitting pipeline rules into established codebases.
*   [INSTALLATION_EN.md](guides/INSTALLATION_EN.md) / [INSTALLATION_RU.md](guides/INSTALLATION_RU.md) — Setting up wrapper paths and configuration.
*   [PUBLICATION_GUIDE_RU.md](guides/PUBLICATION_GUIDE_RU.md) — Publishing guides in Russian.

### 📂 [Concepts](concepts)
Theoretical models and core definitions:
*   [OPERATING_MODEL.en.md](concepts/OPERATING_MODEL.en.md) / [OPERATING_MODEL.ru.md](concepts/OPERATING_MODEL.ru.md) — State-machine lifecycle and checkpoints.
*   [MLSD_APPLICABILITY.en.md](concepts/MLSD_APPLICABILITY.en.md) / [MLSD_APPLICABILITY.ru.md](concepts/MLSD_APPLICABILITY.ru.md) — Model-in-the-loop system development standards.
*   [TECHNICAL_NOTES.md](concepts/TECHNICAL_NOTES.md) — Storage structure and shell constraints.

### 📂 [Reference](reference)
Cheatsheets and prompt templates:
*   [COMMANDS_CHEATSHEET.en.md](reference/COMMANDS_CHEATSHEET.en.md) / [COMMANDS_CHEATSHEET.ru.md](reference/COMMANDS_CHEATSHEET.ru.md) — CLI reference cheat sheets.
*   [COMPANION_SYSTEM_PROMPT_GPT55_v1.1.1a.md](reference/COMPANION_SYSTEM_PROMPT_GPT55_v1.1.1a.md) — Reference system instructions.

### 📂 [Maintainers](maintainers)
Checklists and templates for pipeline development and future scoping:
*   [RELEASE_CHECKLIST.md](maintainers/RELEASE_CHECKLIST.md) — Checklist for building releases.
*   [V1.2_DEFINITION_OF_DONE.md](maintainers/V1.2_DEFINITION_OF_DONE.md) — Roadmap DoD specs.
*   [V1.2_NEXT_PHASE_PROMPT.md](maintainers/V1.2_NEXT_PHASE_PROMPT.md) — Automation templates.

### 📂 [Archive](archive)
*   [README.md](archive/README.md) — Information about archived documents.

## ChatGPT Companion

- [ChatGPT Companion Pack v1.2.1](companion/README.md)

## Distribution and maintenance

- [Distribution Integrity v1.2.3](maintainers/DISTRIBUTION_INTEGRITY_v1.2.3.md)
- [Pipeline Version Matrix](PIPELINE_VERSION_MATRIX.md)
