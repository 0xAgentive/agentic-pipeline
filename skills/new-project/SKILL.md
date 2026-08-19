---
name: new-project
description: Scaffolds and bootstraps a brand-new project repository under Agentic Pipeline v1.2.27 with Git, Action Bridge, and Companion Context ZIP.
---

# /new-project

Bootstrap a brand-new repository with full pipeline governance from scratch.

## Instructions
When invoked with /new-project <ProjectName> or when the user asks to create a new project:
1. Run the scaffolding script:
   ``powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Администратор\.gemini\config\skills\agentic-project-scaffold\scripts\New-AgenticProject.ps1" -ProjectName "<ProjectName>" -Mode New
   ``
2. Report the results cleanly to the user.