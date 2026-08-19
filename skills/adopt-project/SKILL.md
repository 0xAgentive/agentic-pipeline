---
name: adopt-project
description: Onboards and retrofits an existing repository under Agentic Pipeline v1.2.27 without mutating existing code.
---

# /adopt-project

Onboard an existing codebase into Agentic Pipeline v1.2.27 without altering existing source files.

## Instructions
When invoked with /adopt-project <Path> or when the user asks to adopt an existing project:
1. Run the onboarding script:
   ``powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Администратор\.gemini\config\skills\agentic-project-scaffold\scripts\New-AgenticProject.ps1" -TargetDirectory "<Path>" -Mode Adopt
   ``
2. Report the results cleanly to the user.