# Product Evidence Control Plane

v1.2 is not “more bureaucracy”. It exists to prevent false readiness.

A project is not ready because the agent says it is ready. It is ready only when the current product goal, requirements, artifacts, UI/report/security gates, tests, and evidence agree.

## Core contracts

### Product Contract

What product is being built now, for whom, and what counts as done.

### Requirement Drift

Every substantial change in user goal must update state/docs/tests before shipcheck.

### Artifact Delivery

If the agent claims a report, ZIP, package, screenshot or evidence artifact exists, it must provide path, size, SHA-256 and contents.

### QA gates

Use as applicable:

- VisualQA for UI;
- ReportQA for generated PDF/HTML/ZIP/CSV;
- SecurityQA for local data, secrets, exports, MCP, sanitizers;
- ArtifactAudit for artifact existence and consistency.

## Shipcheck rule

`/shipcheck` returns either `SHIP` or `NO-SHIP`.

It must return `NO-SHIP` if:

- tests/builds are missing or failing;
- required artifacts are missing;
- unresolved requirement deltas remain;
- report/visual/security gates are required but absent;
- model prose is the only evidence;
- product contract no longer matches implemented behavior.
