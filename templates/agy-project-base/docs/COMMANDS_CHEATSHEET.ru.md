# Краткая карта команд

Канонический список находится в `config/command-inventory.json`; для каждой команды ниже поставляется workflow.

## Спецификация и планирование

- `/specdoc` - создать или обновить документы продукта и ТЗ без реализации.
- `/planonly` - создать фазовый план реализации и проверок.
- `/probephase` - выполнить один ограниченный технический probe.

## Ориентация и аудит

- `/triage` - классифицировать запрос и рекомендовать следующую безопасную команду.
- `/landing` - восстановить контекст проекта без реализации.
- `/auditphase` - read-only проверка состояния, claims, evidence и blockers.
- `/codebase-map` - построить ограниченную структурную карту кодовой базы.
- `/parallel-audit` - независимые read-only audit lanes без записи исходников.

## Реализация и исправления

- `/nextphase` - реализовать ровно одну утверждённую фазу и остановиться.
- `/fastpatch` - маленькая script-gated UI/style правка с обязательным post-edit `-RequireChanges`.
- `/fixcritical` - исправить только ранее подтверждённые критические blockers.
- `/phasebatch` - отключён по умолчанию и требует явного разрешения человека.
- `/lessons` - записать candidate lessons без изменения durable runtime rules.

## Evidence gates

- `/visualqa` - проверить UI evidence.
- `/reportqa` - проверить отчёты и export bundles.
- `/securityaudit` - read-only security/privacy audit.
- `/artifactaudit` - проверить наличие артефактов, индекс, размер и хеши.
- `/shipcheck` - финальное evidence-based решение `SHIP` или `NO-SHIP`.

## Публикация GitHub

- `/githubprepare` - подготовить двуязычные файлы публикации без push.
- `/githubsync` - commit/push через детерминированные локальные `git` и `gh` scripts.

## Когда остановиться

Остановись, если действие не соответствует `.agy/PHASE_STATUS.json`, отсутствует детерминированное evidence или write-capable tool требует approval.
