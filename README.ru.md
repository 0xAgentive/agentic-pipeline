# Agentic Development Pipeline для Google Antigravity

Версия: `1.1.1`  
Статус: пакет для публичного аудита и выгрузки на GitHub.

Пакет содержит playbook, шаблон проекта, workflows, rules, hooks, skills, Windows/MCP-обходы, `/fastpatch`, audit checklist и инструкции на русском и английском.

## Быстрый старт через Bash

```bash
git clone https://github.com/<OWNER>/<REPO>.git
cd <REPO>
bash scripts/bash/validate-package.sh
```

Внедрить пайплайн в существующую папку:

```bash
bash scripts/bash/adopt-pipeline.sh "/path/to/existing/project"
```

В Git Bash на Windows:

```bash
bash scripts/bash/adopt-pipeline.sh "/c/Users/<User>/Documents/antigravity/MyProject"
```

После внедрения открой папку проекта в Antigravity и запусти:

```text
/landing
/codebase-map
/auditphase
```

## Windows PowerShell

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\Apply-AgenticPipeline-v1.1.1.ps1 `
  -TargetRoot "$env:USERPROFILE\Documents\antigravity\MyProject" `
  -TemplateRoot ".\templates\agy-project-base" `
  -UpdateMcpConfig
```

## Публикация на GitHub

```bash
bash scripts/bash/validate-package.sh
git init
git add .
git commit -m "Initial public release of Agentic Development Pipeline"
git branch -M main
git remote add origin https://github.com/<OWNER>/<REPO>.git
git push -u origin main
```

## Важная политика

- Самоотчёты LLM не являются верификацией.
- Истина — exit code, тесты, diff, логи, скриншоты и артефакты.
- `/fastpatch` разрешается только скриптом `Test-FastPatchAllowed.ps1`.
- Codebase Memory на Windows индексируется через RPC-скрипт, не через CLI `index_repository`.
