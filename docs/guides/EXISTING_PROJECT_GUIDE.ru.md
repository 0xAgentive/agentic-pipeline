# Подключение существующего проекта

Не подключай и не обновляй pipeline во время активной продуктовой фазы.

## Предусловия

- текущая продуктовая фаза завершена;
- рабочее дерево чистое или явно проверено;
- понятен статус тестов/сборки;
- есть rollback или backup.

## Windows

Dry-run:

```powershell
$Repo = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
$Project = "C:\path\to\existing-project"
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode Adopt -TargetRoot $Project
```

Применение после проверки:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\scripts\windows\Initialize-AgenticProject.ps1" -Mode Adopt -TargetRoot $Project -Apply
```

По умолчанию действует конфликтная политика `Keep`. Существующие файлы и состояние `.agy` не заменяются молча. Новый adoption-профиль начинается с `/landing`, затем `/auditphase`.
