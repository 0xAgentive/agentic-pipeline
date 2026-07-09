# Как обновлять ChatGPT companion и Antigravity pipeline вместе

## Когда обновлять companion

Обновляйте companion, если изменилось:

- как формулировать ТЗ;
- как анализировать чужие планы;
- как разделять ChatGPT и Antigravity;
- как проверять evidence;
- как объяснять pipeline пользователю;
- какие lessons извлечены из реальных проектов.

## Когда обновлять pipeline repo

Обновляйте `agentic-pipeline`, если изменилось:

- README / public docs;
- шаблон проекта;
- workflow/rule/hook/script;
- validators;
- GitHub publication scripts;
- package/release files.

## Когда обновлять active project

Обновляйте активный проект только отдельной фазой, если:

- текущая фаза завершена;
- tests/build green;
- audit подтвердил безопасное окно;
- есть migration plan.

## Нельзя

- считать, что companion update автоматически обновил Antigravity;
- считать, что repo docs update автоматически мигрировал H10;
- менять pipeline посреди active feature work;
- пушить framework patch без validation.
