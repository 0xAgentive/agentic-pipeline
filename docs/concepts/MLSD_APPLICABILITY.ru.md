# Применимость Machine Learning System Design к Agentic Pipeline

Agentic Pipeline управляет недетерминированным исполнителем — агентом, который может звучать уверенно, но ошибаться. Поэтому к нему применимы принципы ML/system design.

## Что принимаем

- Problem frame перед high-risk работой.
- Cost of mistake / risk model.
- Живые требования и requirement drift.
- Baseline перед claims об улучшении.
- Evals для поведения workflow.
- Error analysis и failure taxonomy.
- Artifact provenance: path, size, SHA-256, contents.
- Runbook, ADR и postmortem-шаблоны.
- Context budget: playbook как reference, не hot path.

## Что не принимаем буквально

- обязательный design doc для каждой мелкой правки;
- enterprise RACI для каждого личного проекта;
- feature store;
- A/B testing как обязательный процесс;
- полноценный ML monitoring stack;
- mandatory API executor;
- mandatory MCP;
- write-capable multi-agent implementation.

## Уровни применения

### Level 1 — простой проект

README, workflows, PHASE_STATUS, basic checks.

### Level 2 — важный проект

Добавить evidence, artifact index, requirement drift.

### Level 3 — данные / безопасность / публикация / health-adjacent

Добавить product contract, risk register, report/security/visual gates.

### Level 4 — сопровождение фреймворка

Добавить evals, metrics, failure taxonomy, runbooks, ADRs.

## Главное правило

Сложность добавляется только после реального failure mode или для высокорисковой работы. Не превращайте framework в бюрократию для маленьких задач.
