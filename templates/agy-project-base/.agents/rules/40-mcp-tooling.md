# MCP and Tooling Rules

- Use the minimum tool surface required by the selected workflow.
- Default to read-only tools.
- No write-capable MCP operation without explicit human approval.
- Do not use MCP output as release truth without deterministic local verification.
- Keep Codebase Memory optional and exclude build output, logs, secrets, raw data and generated artifacts.
- Use browser tools only for explicit visual/browser verification.

## Codebase Memory Graph Discipline (Token & Context Optimization)

- Before conducting broad multi-file searches or reading entire multi-hundred-line files, query `codebase-memory`:
  - `search_graph(query)` to find exact entity definitions and containing files.
  - `trace_path(Caller, Callee)` to inspect call graph relationships without dumping intermediate files.
  - `get_code_snippet(symbol)` to fetch ONLY the relevant function/class AST snippet instead of entire source files.
- Fall back to `grep_search` / `find_by_name` only when graph symbols are unavailable or for configuration/doc strings.
