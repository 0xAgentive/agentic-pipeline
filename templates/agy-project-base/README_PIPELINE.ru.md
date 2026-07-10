# Шаблон проекта Agentic Pipeline

Это самодостаточный шаблон проекта для runtime Agentic Pipeline `1.2.0`.

## Цикл нового проекта

1. `/specdoc`
2. `/planonly`
3. `/auditphase`
4. `/nextphase`
5. необходимые visual/report/security/artifact gates
6. `/shipcheck`

Начальное состояние шаблона - `new-project`, поэтому `.agy/PHASE_STATUS.json` сначала требует `/specdoc`.

Для существующего репозитория не копируй шаблон вручную поверх активной разработки. Используй установщик в режиме `adopt-existing` только после завершения текущей продуктовой фазы и проверки рабочего дерева.

## Локальная документация

- [Быстрый старт](docs/START_HERE.ru.md)
- [Краткая карта команд](docs/COMMANDS_CHEATSHEET.ru.md)
- [Операционная модель](docs/OPERATING_MODEL.ru.md)
- [Публикация на GitHub](docs/GITHUB_PUBLICATION.md)

Текст модели не является проверкой. Проверкой являются детерминированные команды, exit codes, тесты, diff, логи, скриншоты и хеши артефактов.
