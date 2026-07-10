# Safety Boundaries

- Do not modify raw/source data roots unless explicitly authorized.
- Do not expose secrets, credentials, full local paths, device identifiers or sensitive records in logs/artifacts.
- Do not enable network, remote execution, write-capable MCP, publishing or deployment without explicit approval.
- Do not run broad destructive cleanup, reset, reformat or dependency changes outside the approved phase.
- Stop when state is unclear, the worktree contains unrelated changes, or required evidence cannot be produced.
