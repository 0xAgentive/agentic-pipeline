# Новый проект

Используется явный профиль состояния `new-project`. Первая команда - `/specdoc`.

## Windows

Dry-run:

```powershell
$Repo = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
$Project = "$env:USERPROFILE\Documents\antigravity\My New Project"
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode New -TargetRoot $Project
```

Применение после проверки:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode New -TargetRoot $Project -Apply
```

Установщик копирует самодостаточный template, создаёт `.agy/INSTALLATION_MANIFEST.json` и выбирает schema-valid профиль `new-project`.

Первые команды:

```text
/specdoc
/planonly
/auditphase
/nextphase
```
