# Start Here

## What is this?

Agentic Pipeline is a small operating manual for using Antigravity agents on real projects.

It prevents the usual failure mode:

```text
agent starts coding
agent changes too much
agent says "done"
tests or product reality disagree
you lose time reconstructing what happened
```

The pipeline forces a simpler loop:

```text
decide what should be built
plan it
implement only the next phase
verify it
record evidence
stop
```

## Initial state profiles

- A freshly installed project uses `new-project` and starts at `/specdoc`.
- An adopted existing repository uses `adopt-existing` and starts at `/landing`, followed by `/auditphase`.

Do not manually reuse one state for both scenarios.

## Which command should I use now?

If you are starting from an idea:

```text
/specdoc
```

If the spec exists but no implementation plan exists:

```text
/planonly
```

If the project already exists and you are not sure what is true:

```text
/auditphase
```

If the plan and audit are clean:

```text
/nextphase

Implement only the next planned phase. Stop after verification and checkpoint.
```

If the UI changed:

```text
/visualqa
```

If the project handles private data, exports, filesystem writes, MCP, credentials, or security-sensitive logic:

```text
/securityaudit
```

If you want to decide whether the project is release-ready:

```text
/shipcheck
```

If this is the first GitHub publication:

```text
/githubprepare
/githubsync
```

If the GitHub repository already exists:

```text
/githubsync
```

## How to avoid breaking an active project

Do not upgrade the pipeline while the agent is editing product code. Finish the current phase first. Then ask for a read-only pipeline audit and migrate only if the workspace is clean.
