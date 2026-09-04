# Agentic Pipeline Companion v1.2.27

This directory contains the canonical sources for the AI Companion (ChatGPT Custom GPT / Project) acting as Chief Architect in the Agentic Pipeline ecosystem.

## File Deployment & Locations

- **Built Companion Package Directory:**
  `%USERPROFILE%\Downloads\Agentic-Pipeline-Companion-1.2.27\`
- **Project Instructions (System Prompt):**
  `01_PROJECT_INSTRUCTIONS_v1.2.27.md` — pasted into ChatGPT Project Instructions / Custom GPT instructions.
- **Knowledge Modules (Project Files):**
  `knowledge/` (modules `00–15`) — uploaded into ChatGPT Knowledge / Project Files.
- **Project Codebase Archive:**
  Generated per project via `/companion-pack` (`companion-packs/<PROJECT>_COMPREHENSIVE_COMPANION_PACK.zip`) or session handoff (`LATEST_CONTEXT.zip`) attached directly to the chat session.

## Building & Verification

- Build package: `pwsh scripts/windows/companion/Build-CompanionPack-v1.2.27.ps1`
- Prepare deployment in Downloads: `pwsh scripts/release/Prepare-AgenticPipeline-Companion-v1.2.27.ps1 -Force`
- Run regression tests: `pwsh scripts/windows/companion/Test-CompanionPack-v1.2.27.ps1`

## Context Handoffs & Dialogue Filtering (conversations.txt)

To limit automated background handoffs (`LATEST_CONTEXT.zip`) to specific active project dialogues:
- Edit `C:\Scripts\AntigravityProjects\companion-handoff\conversations.txt`
- Add allowed Conversation IDs (one per line):
  ```text
  c0f55ce7-2989-4557-8cb0-e1f7980033e3   # Huawei Health export
  4e568acf-a6a6-48f1-8b08-789a4210a93b   # H10 Athlete Cardio Lab
  ```
- Hot-reloaded dynamically on each agent pause without restarting any service. Use `#` to comment out or `*` to allow all.

