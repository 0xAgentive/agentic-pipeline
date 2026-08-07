# /fixcritical

Goal: repair all open, confirmed, auto-repairable product blockers in the current owner-approved work item.

Prerequisites: active work item; exact execution lease; active stage firewall; schema-valid findings; current candidate identity or an explicitly invalidated manifest.

Behavior:
1. Group related findings by subsystem and repair the smallest coherent group.
2. Continue automatically while `PROGRESS_STATE.json` shows measurable progress.
3. Register late findings without asking the owner and keep the same work item.
4. Re-run focused and affected regression checks after each coherent repair.
5. Publish repair delta, progress state and next action.
6. Stop only for a true owner decision or two repeated no-progress outcomes.

Continue confirmed repairs automatically while measurable progress is observed.
