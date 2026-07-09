# Как понять, в каком пайплайне работает проект

Открой корень проекта и проверь:

```powershell
Get-Content .agy\PHASE_STATUS.json -Raw
Get-ChildItem .agents\workflows | Select-Object Name
Get-ChildItem .agents\rules | Select-Object Name
Test-Path .agy\PRODUCT_CONTRACT.json
Test-Path .agy\evidence.ndjson
Test-Path .agy\ARTIFACT_INDEX.ndjson
Test-Path runtime-src
```

Если есть только `.agy/PHASE_STATUS.json`, `.agents/workflows`, `.agents/rules`, но нет `PRODUCT_CONTRACT.json`, `evidence.ndjson`, `ARTIFACT_INDEX.ndjson`, `runtime-src`, проект работает по текущему v1.1.x/r4b-style pipeline.

Если есть Product Contract, Requirement Delta, Artifact Index, machine evidence and runtime-src, проект уже мигрирует к v1.2 Product Evidence Control Plane.

## Когда мигрировать к v1.2

Не в середине активной feature-фазы.

Правильный момент:
1. текущая фаза завершена;
2. typecheck/test/build проходят;
3. `/auditphase` чистый или понятный;
4. `/shipcheck` не blocked;
5. миграция запланирована отдельной `/planonly` и выполняется отдельной `/nextphase`.

## Что такое v1.2 простыми словами

v1.2 делает проверяемыми не только код и тесты, но и продуктовую цель, артефакты, отчёты, визуальные проверки и evidence. Это полезно для сложных проектов, но не должно мешать текущей активной фазе.
