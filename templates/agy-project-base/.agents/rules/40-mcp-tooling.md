# MCP and Tooling Rules

- Use the minimum tool surface required by the selected workflow.
- Default to read-only tools.
- No write-capable MCP operation without explicit human approval.
- Do not use MCP output as release truth without deterministic local verification.
- Keep Codebase Memory optional and exclude build output, logs, secrets, raw data and generated artifacts.
- Use browser tools only for explicit visual/browser verification.
