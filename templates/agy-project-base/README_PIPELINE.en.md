# Agentic Pipeline project template

This is a self-contained project template for Agentic Pipeline runtime `1.2.0`.

## New project lifecycle

1. `/specdoc`
2. `/planonly`
3. `/auditphase`
4. `/nextphase`
5. the required visual/report/security/artifact gates
6. `/shipcheck`

The distributed initial state is `new-project`, so `.agy/PHASE_STATUS.json` requires `/specdoc` first.

For an existing repository, do not copy this template manually over active work. Use the installer in `adopt-existing` mode only after the current product phase is complete and the worktree is understood.

## Local documentation

- [Start here](docs/START_HERE.en.md)
- [Command cheat sheet](docs/COMMANDS_CHEATSHEET.en.md)
- [Operating model](docs/OPERATING_MODEL.en.md)
- [GitHub publication](docs/GITHUB_PUBLICATION.md)

Model prose is not verification. Trust deterministic commands, exit codes, tests, diffs, logs, screenshots and artifact hashes.
