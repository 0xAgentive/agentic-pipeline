# Обновление Pipeline 1.2.6, Runtime 1.2.3 и Companion 1.2.4

1. Обновите локальный репозиторий и GitHub скриптом release kit.
2. В ChatGPT Project полностью замените Project Instructions содержимым `01_PROJECT_INSTRUCTIONS_v1.2.4.md`.
3. В Project Sources оставьте по одной копии файлов `knowledge/00–15`.
4. Удалите активные модули Companion 1.2.3 и ниже.
5. Для Antigravity-проекта сначала завершите активный work item, затем выполните `Update-AgenticProjectRuntime-v1.2.3.ps1` в dry-run и только потом с `-Apply`.

Runtime updater изменяет только allowlist framework-owned файлов, создаёт резервные копии и сохраняет product source, project docs, `WORK_ITEM.json`, результаты и существующее состояние проекта.
