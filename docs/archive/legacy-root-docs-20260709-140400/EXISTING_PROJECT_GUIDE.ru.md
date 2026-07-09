# Действующий проект

Используй это, когда проект уже существует и нужно безопасно продолжить.

## Шаг 1. Прочитать состояние

```powershell
Get-Content .agy\PHASE_STATUS.json -Raw
Get-Content .agy\AGENT_STATE.md -Raw
git status --short
```

## Шаг 2. Если не уверен — read-only аудит

```text
/auditphase

Do not implement code.
Inspect current state, changed files, checks, risks and next required command.
Stop after the audit report.
```

## Шаг 3. Продолжать только ожидаемой командой

Если `PHASE_STATUS.json` говорит `/securityaudit`, запускай `/securityaudit`.
Если говорит `/shipcheck`, запускай `/shipcheck`.
Если говорит `/nextphase`, реализуй только одну запланированную фазу.

## Шаг 4. Не мигрировать пайплайн посреди фазы

Обновление пайплайна — это инфраструктурная задача. Делай её только когда:
- текущая фаза завершена;
- tests/build проходят;
- git diff понятен;
- состояние не blocked.

## Шаг 5. GitHub

Первая публикация:

```text
/githubprepare
/githubsync
```

Обновления:

```text
/githubsync
```
