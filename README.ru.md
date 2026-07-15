# Agentic Development Pipeline

Локальный, строгий и проверяемый фреймворк для управления разработкой с AI-агентами в Google Antigravity.

Agentic Pipeline помогает не допускать дрейфа состояния, перескакивания фаз и неподтверждённых заявлений о готовности.

**Текущий пакет:** `1.2.4 Governance & Routing Stabilization`
**Канонический playbook:** `1.2.0`
**Runtime:** `1.2.1`
**ChatGPT Companion:** `1.2.2`

---

## Ценность и назначение

AI-ассистенты быстро пишут код, но часто ошибаются в процессе:

1. Агент начинает реализовывать задачу.
2. Меняет десятки файлов в разных частях проекта.
3. Объявляет задачу завершённой на основании собственной логики.
4. Сборка или тесты падают, либо review показывает нежелательные побочные эффекты.

**Agentic Pipeline решает эту проблему.** Он задаёт пошаговый цикл, где агент не переходит к следующей фазе без детерминированных доказательств: успешных проверок, чистого diff, точных команд терминала и явного подтверждения человека на границах фаз.

---

## Для кого это

- **Разработчики**, которые используют продвинутых AI-агентов, но хотят сохранять контроль над архитектурой и качеством кода.
- **Тимлиды**, которым нужны правила безопасной AI-разработки в команде.
- **Security и QA**, которым нужны проверяемые следы изменений и audit-ready evidence.

---

## Трёхслойная операционная модель

    ChatGPT Companion
      -> формулирует идеи, готовит ТЗ, проводит research и audit, пишет prompts

    Agentic Pipeline
      -> задаёт workflows, rules, hooks, validators, evidence gates

    Product Project
      -> содержит реальный код, тесты, .agy state и артефакты проверки

1. **ChatGPT Companion** - слой мышления, research, аудита и подготовки точных prompts. Это не исполнитель.
2. **Agentic Pipeline** - слой процесса: workflows, durable rules, hooks, skills, validators и шаблоны.
3. **Product Project** - рабочая папка приложения или инструмента, где находятся исходники, тесты и доказательства выполнения.

Важный инвариант: слова модели в чате не являются проверкой. Проверкой являются команды, exit codes, тесты, diff, скриншоты, логи и артефакты внутри workspace.

---

## Быстрый старт

### Новый проект в Windows

Сначала запусти детерминированный установщик в dry-run режиме:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Initialize-AgenticProject.ps1 -Mode New -TargetRoot "$env:USERPROFILE\Documents\antigravity\My New Project"
```

После проверки добавь `-Apply`. Новый проект всегда начинается с:

```text
/specdoc
```

### Подключение существующего проекта

Это отдельная инфраструктурная операция. Сначала закончи активную продуктовую фазу, затем запусти:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Initialize-AgenticProject.ps1 -Mode Adopt -TargetRoot "C:\path\to\existing-project"
```

После проверки добавь `-Apply`. Adoption начинается с `/landing`, затем `/auditphase`. Существующее состояние `.agy` не перезаписывается молча.

---

## Карта команд

- `/specdoc` - создать или обновить спецификацию без кода.
- `/planonly` - создать фазовый план без реализации.
- `/auditphase` - проверить текущее состояние workspace.
- `/probephase` - проверить рискованные API, данные, железо или права.
- `/nextphase` - реализовать ровно одну фазу, проверить, зафиксировать состояние и остановиться.
- `/fastpatch` - маленькая правка только если скрипт разрешил diff.
- `/visualqa` - визуальная проверка UI.
- `/securityaudit` - проверка приватности, секретов, экспорта и опасных действий.
- `/shipcheck` - финальная проверка SHIP / NO-SHIP.
- `/githubprepare` - подготовка GitHub-публикации.
- `/githubsync` - безопасный commit/push после проверок.

---

## Evidence-first SHIP / NO-SHIP

Релизное решение бинарно:

- **SHIP** - только если состояние `.agy/PHASE_STATUS.json` согласовано, проверки пройдены, evidence присутствует, риски закрыты или явно приняты.
- **NO-SHIP** - если есть failed command, непроверенные claims, отсутствующие rollback notes, visual/security/report blockers или дрейф требований.

---

## ChatGPT Companion

Отдельный companion-пакет для ChatGPT лежит в [docs/companion/](docs/companion/). Его задача - помогать формулировать требования, проводить аудит, готовить Agent Task Pack и писать точные prompts для Antigravity. Companion не является исполнителем и не заменяет workspace evidence.

---

## Навигация по документации

- Старт: [START_HERE.en.md](docs/START_HERE.en.md) / [START_HERE.ru.md](docs/START_HERE.ru.md)
- Context Split: [CONTEXT_SPLIT.ru.md](docs/concepts/CONTEXT_SPLIT.ru.md)
- Companion Pack: [docs/companion/README.md](docs/companion/README.md)
- Индекс документации: [docs/README.md](docs/README.md)
- Матрица версий: [docs/PIPELINE_VERSION_MATRIX.md](docs/PIPELINE_VERSION_MATRIX.md)

---

## Лицензия

Проект распространяется под лицензией MIT. Подробности в файле [LICENSE](LICENSE).
