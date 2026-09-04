# Руководство по установке и обновлению Companion v1.2.27

Это руководство описывает, как настроить ChatGPT Project или Custom GPT для роли Главного Архитектора и Стратега в экосистеме Agentic Pipeline.

---

## 📁 1. Где лежат файлы на диске

Все готовые файлы дистрибутива Компаньона находятся в папке:
```text
%USERPROFILE%\Downloads\Agentic-Pipeline-Companion-1.2.27\
```
*(Исходники в репозитории ядра: `docs/companion/`)*

Внутри этой папки находятся:
- `01_PROJECT_INSTRUCTIONS_v1.2.27.md` — системные инструкции (промпт для поля Instructions);
- `knowledge\` — каталог с 16 модулями базы знаний экосистемы;
- `CHATGPT_PROJECT_UPDATE_CHECKLIST.txt` — быстрый чек-лист обновления.

---

## ⚙️ 2. Что загружается в ChatGPT Project / Custom GPT

### Шаг A. Инструкции проекта (Instructions / System Prompt)
Откройте настройки вашего GPT/Project (вкладка **Configure**) и в поле **Instructions** вставьте полный текст файла:
```text
%USERPROFILE%\Downloads\Agentic-Pipeline-Companion-1.2.27\01_PROJECT_INSTRUCTIONS_v1.2.27.md
```

### Шаг B. База знаний / Файлы проекта (Knowledge / Project Files)
В разделе **Knowledge (Файлы проекта / База знаний)** удалите устаревшие файлы и загрузите ровно по одной копии **всех 16 файлов** из папки:
```text
%USERPROFILE%\Downloads\Agentic-Pipeline-Companion-1.2.27\knowledge\
```

Список файлов базы знаний:
1. `00_AGENTIC_PIPELINE_INDEX_v1.2.27.md` — индекс и архитектура экосистемы.
2. `01_CONTEXT_SPLIT_POLICY.md` — разделение ответственности между ИИ-стратегом и локальным агентом.
3. `02_AGENT_TASK_PACK_CONTRACT_v1.2.27.md` — контракт формирования JSON Action Packet и 5 канонических маршрутов (`/nextphase`, `/fixcritical`, `/auditphase`, `/fastpatch`, `/shipcheck`).
4. `03_PRODUCT_EVIDENCE_CONTROL_PLANE.md` — стандарты сбора доказательств и артефактов.
5. `04_PROJECT_AUDIT_AND_RECOVERY.md` — правила восстановления и независимого аудита.
6. `05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md` — доменные уроки и фиксация опыта.
7. `06_RUNTIME_TRUTH_REVIEW_POLICY.md` — верификация фактов против галлюцинаций.
8. `07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md` — маршрутизация и конечный автомат фаз.
9. `08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md` — политика фазового прогресса.
10. `09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md` — классификация блокеров и уровни доказательств.
11. `10_STATUS_AND_FINDING_LIFECYCLE.md` — жизненный цикл замечаний аудита.
12. `11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md` — компиляция промптов и авторитет результатов.
13. `12_GOLDEN_EVALS.md` — эталонные сценарии тестирования.
14. `13_LOCAL_CONTROL_TOOLS.md` — локальные инструменты управления средой.
15. `14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md` — правила автономной сходимости.
16. `15_OWNER_OUTPUT_PRESENTATION.md` — компактный формат отчёта для владельца (4 секции).

---

## 🗂️ 3. Загрузка контекста конкретного проекта в чат

Когда вы начинаете работу над конкретным репозиторием (например, H10, PulseTracker):
1. Выполните команду `/companion-pack` в терминале Antigravity (или используйте автоматический handoff-архив);
2. Прикрепите полученный файл кодовой базы:
   `companion-packs\<PROJECT>_COMPREHENSIVE_COMPANION_PACK.zip` (или `LATEST_CONTEXT.zip`) к сообщению в диалоге с Компаньоном;
3. Компаньон изучит код и сформирует однофайловый `AGENTIC_ACTION_PACKET_<project>_<timestamp>.json`, который при скачивании в `Downloads` будет мгновенно подхвачен фоновым сервисом Action Bridge.

---

## ⚡ 4. Управление автоматическими хэндофами (фильтр conversations.txt)

Чтобы автоматические хэндофы (`LATEST_CONTEXT.zip`) и копирование пути в буфер обмена формировались только для нужных рабочих диалогов:
1. Откройте текстовый файл:
   ```text
   C:\Scripts\AntigravityProjects\companion-handoff\conversations.txt
   ```
2. Впишите разрешённые ID диалогов (по одному на строку):
   ```text
   c0f55ce7-2989-4557-8cb0-e1f7980033e3   # Huawei Health export
   4e568acf-a6a6-48f1-8b08-789a4210a93b   # H10 Athlete Cardio Lab
   ```
3. Сохраните файл. Изменения применяются **мгновенно на лету** при следующей паузе агента (Hot-Reload). Никаких команд или перезапусков не требуется!
4. Для временного отключения поставьте перед ID символ `#`. Для разрешения всех диалогов укажите `*`.

