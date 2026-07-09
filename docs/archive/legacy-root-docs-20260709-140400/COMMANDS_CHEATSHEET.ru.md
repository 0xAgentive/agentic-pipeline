# Шпаргалка команд

## Основные команды

`/specdoc` — только ТЗ и документы. Без кода.

`/planonly` — только план реализации. Без кода.

`/auditphase` — проверка текущего состояния, рисков, документов и проверок. Без feature work.

`/probephase` — ограниченное локальное исследование. Без реализации, если явно не разрешено.

`/nextphase` — реализация только одной утверждённой фазы.

`/fastpatch` — маленькая UI/style правка только если скрипт-гейт разрешил.

`/visualqa` — проверка UI, браузера, скриншотов, console, читаемости.

`/securityaudit` — приватность, экспорты, файловая система, MCP, секреты, внешние вызовы.

`/shipcheck` — решение по релизу. Только SHIP или NO-SHIP на основе deterministic evidence.

`/githubprepare` — подготовка README, license, security docs, templates перед первой публикацией.

`/githubsync` — commit/push через git/gh.

## Полезные формулировки

```text
Implement only the next planned phase. Stop after verification and checkpoint.
```

```text
Do not implement code. Audit only. Stop after the report.
```

```text
Do not write SHIP unless all deterministic checks and required evidence pass.
```

## Когда останавливать агента

Остановить, если агент хочет:
- менять исходные данные;
- просить admin/elevation;
- добавить cloud upload;
- использовать write-capable MCP без approval;
- пропустить тесты;
- публиковать без validation;
- автоматически начать следующую фазу.
