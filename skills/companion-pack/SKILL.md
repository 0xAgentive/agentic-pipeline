---
name: companion-pack
description: Extracts, packages, and formats pure architectural context of the active repository into a compact 1-2 MB ZIP for ChatGPT / Claude.
---

# /companion-pack

Extracts clean architectural source code into a lightweight ZIP package for LLM Companions.

## Instructions
When invoked with /companion-pack or /companion-context:
1. Run the context pack script:
   ``powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Администратор\.gemini\config\skills\companion-project-context-pack\scripts\New-CompanionProjectContextPack.ps1"
   ``
2. Report the generated ZIP path under LOCAL ARTIFACTS.