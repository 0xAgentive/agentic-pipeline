# Новый проект с нуля

Используй это, когда есть сырая идея и нужно начать новый проект.

## Шаг 1. Создать папку

```powershell
$Project = "$env:USERPROFILE\Documents\antigravity\My New Project"
New-Item -ItemType Directory -Force $Project | Out-Null
Set-Location $Project
```

## Шаг 2. Скопировать базовый шаблон

```powershell
$Template = "$env:USERPROFILE\Documents\antigravity\_templates\agy-project-base"
Copy-Item "$Template\*" $Project -Recurse -Force
Copy-Item "$Template\.agents" $Project -Recurse -Force
Copy-Item "$Template\.agy" $Project -Recurse -Force
Copy-Item "$Template\.cbmignore" $Project -Force
```

## Шаг 3. Открыть папку в Antigravity

Начни с:

```text
/specdoc
```

Агент должен создать документы проекта. Код пока не писать.

## Шаг 4. Сделать план

```text
/planonly
```

На выходе нужны фазы, проверки, риски и точная следующая команда.

## Шаг 5. Реализовать одну фазу

```text
/nextphase

Implement only the next planned phase. Stop after verification and checkpoint.
```

## Шаг 6. Проверить и публиковать

Используй только нужные gates:

```text
/visualqa
/securityaudit
/shipcheck
/githubprepare
/githubsync
```

## Простое правило

Если проект работает с приватными данными, экспортом, локальными файлами, деньгами, health-like данными или опасными действиями, используй строгий путь. Не включай `/phasebatch`.
