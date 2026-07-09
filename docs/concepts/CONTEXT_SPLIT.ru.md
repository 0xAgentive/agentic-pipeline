# Разделение контекста: ChatGPT companion и Antigravity pipeline

В этой системе есть два связанных продукта.

## 1. ChatGPT Project companion

Путь у владельца может выглядеть так:

```text
G:\Мой диск\Obsidian Vault\4-Context&Prompts\5-Antigravity\agentic_pipeline_companion_pack
```

Назначение:

- превратить сырую идею в ТЗ;
- подготовить Agent Task Pack;
- проверить предложения других моделей;
- проанализировать логи, скриншоты, артефакты;
- определить следующий безопасный prompt для Antigravity;
- не выполнять кодовые изменения в репозитории.

## 2. Antigravity pipeline repository

Путь у владельца может выглядеть так:

```text
C:\Users\Администратор\Documents\antigravity\agentic-pipeline
```

Назначение:

- хранить публичный framework;
- хранить шаблон проекта;
- хранить workflows/rules/hooks/scripts;
- обновлять GitHub;
- давать другим людям понятный старт.

## 3. Active project workspace

Пример:

```text
C:\Users\Администратор\Documents\antigravity\H10 Athlete Cardio Lab
```

Назначение:

- хранить код продукта;
- хранить проектную `.agy` state;
- выполнять конкретные фазы;
- производить доказательства, тесты и артефакты.

## Правило

Не переносите всё во все места.

- Companion получает reasoning, research, task framing.
- Pipeline получает executable docs/templates/scripts.
- Active project получает только то, что нужно текущему проекту и только через отдельную phase migration.

## Когда мигрировать активный проект на новую версию пайплайна

Только после:

1. текущая фаза завершена;
2. тесты/билды зелёные;
3. `.agy/PHASE_STATUS.json` не противоречит реальности;
4. `/auditphase` подтвердил безопасное окно;
5. `/planonly` подготовил migration plan.

Нельзя мигрировать pipeline посреди активной feature-фазы.
