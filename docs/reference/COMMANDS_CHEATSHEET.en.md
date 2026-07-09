# Command Cheat Sheet

## Core commands

`/specdoc` — write product/spec docs only.

`/planonly` — write implementation plan only.

`/auditphase` — inspect current state, risks, docs, checks. No feature work.

`/probephase` — bounded local investigation. No implementation unless explicitly allowed.

`/nextphase` — implement one approved phase only.

`/fastpatch` — tiny UI/style patch only if the script gate allows it.

`/visualqa` — verify UI/browser/screenshots/console/readability.

`/securityaudit` — verify privacy, exports, filesystem, MCP, secrets, remote calls.

`/shipcheck` — release decision. Output must be SHIP or NO-SHIP based on deterministic evidence.

`/githubprepare` — prepare README, license, security docs, templates for first GitHub publication.

`/githubsync` — commit and push through deterministic git/gh commands.

## Safe phrases to use

```text
Implement only the next planned phase. Stop after verification and checkpoint.
```

```text
Do not implement code. Audit only. Stop after the report.
```

```text
Do not write SHIP unless all deterministic checks and required evidence pass.
```

## When to stop

Stop if the agent wants to:
- modify source data;
- use admin/elevation;
- add cloud upload;
- use write-capable MCP without approval;
- skip tests;
- publish without validation;
- start the next phase automatically.
