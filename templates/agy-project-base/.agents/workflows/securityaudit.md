---
description: Read-only security and privacy audit with deterministic evidence.
---

# /securityaudit

## Mode

Read-only unless a later `/fixcritical` or `/nextphase` explicitly authorizes remediation.

## Check

- secrets, credentials and environment access;
- path traversal, command execution and unsafe deserialization;
- remote/network calls and local-only boundaries;
- logging/redaction of sensitive data;
- report/export leakage;
- write-capable MCP or external tool permissions;
- dependency and configuration risks relevant to the change.

## Output

Findings with severity, path, evidence, exploitability/impact, recommended fix and shipcheck effect.

Missing or unverified critical controls block `/shipcheck`.
