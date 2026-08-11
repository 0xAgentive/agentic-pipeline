# Auto Context Handoff v4.3.4

Автоматический экспортёр контекста для Antigravity Desktop → ChatGPT Companion.

```text
Antigravity завершает ответ
→ система создаёт LATEST_CONTEXT.zip
→ открывает папку с ZIP
→ копирует в буфер сообщение для Companion
→ владелец загружает ZIP в новый чат Companion
→ Companion продолжает работу
```

## Компоненты

| Модуль | Назначение |
|---|---|
| `enqueue_ag_handoff.py` | Stop-hook: приём события, дедупликация, очередь |
| `export_ag_handoff.py` | Оркестратор экспорта |
| `capture_session_context.py` | Захват transcript delta, touched files, commands |
| `project_root_resolver.py` | Определение корней проекта |
| `git_snapshot.py` | Снимок Git-состояния |
| `authority_collector.py` | Сбор и скоринг authority-файлов |
| `result_identity.py` | Привязка work item → artifact |
| `artifact_verifier.py` | Многоуровневая верификация артефактов |
| `runtime_status.py` | Оценка slash/runtime readiness |
| `continuation_policy.py` | Политика продолжения работы |
| `package_builder.py` | Сборка ZIP, manifest, atomic publish |
| `package_validator.py` | Валидация закрытого ZIP |
| `diagnostics.py` | Коды ошибок, диагностика |
| `run_ag_handoff_worker.py` | Фоновый worker с PID-lock |
| `run_ag_ux_helper.py` | Clipboard, Explorer, notification |

## Структура каталогов

```
companion-handoff/
├── src/                    # исходный код
├── install/                # установщики и тесты
├── schemas/                # JSON-схемы
├── templates/              # шаблоны
├── handoffs/               # экспортированные handoff-пакеты
├── queue/                  # очередь Stop-событий
├── state/                  # состояние по conversation
├── logs/                   # логи и диагностика
└── release/                # релизные пакеты
```

## Установка

```powershell
pwsh -File install/Install-AntigravityCompanionHandoff.ps1
```

## Тестирование

```powershell
python -B install/run_tests.py
```

## Версия

Все поверхности: `4.3.4`
