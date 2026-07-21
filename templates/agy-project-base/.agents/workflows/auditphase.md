---
description: Independent read-only verification of the current work item and actual product artifacts.
---

# /auditphase

## Mode

Read-only. Do not repair findings in this workflow.

## Read

- `.agy/WORK_ITEM.json`;
- `.agy/EXECUTION_SCOPE.json`;
- `.agy/RUN_RESULT.json`;
- current Git diff and status;
- actual product artifacts and product-specific validators;
- relevant requirements and safety/privacy rules.

## Verify

- work item and run result refer to the same `work_item_id`;
- changed paths stay inside the exact execution scope;
- required commands actually exited successfully;
- product and verification claims match actual bytes/behavior;
- service warnings do not masquerade as product blockers;
- release-only gaps do not block FLOW/GUARDED product acceptance;
- GUARDED and RELEASE checks are independent from implementation claims.

## Result

- product blocker: update `RUN_RESULT.json`, then continue through `/fixcritical` without owner approval;
- verification blocker: remain in audit until verified;
- service warning: reconcile automatically and do not block;
- PASS: mark the work item completed;
- outside-scope or hard stop: request one owner decision.

Output one verdict, material blockers, checks and artifact paths. No hash ceremony in normal product work.
