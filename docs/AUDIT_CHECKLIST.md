# Audit Checklist

## Package

- [ ] README.md and README.ru.md exist.
- [ ] LICENSE exists and holder is correct.
- [ ] SECURITY.md has a real contact before publication.
- [ ] CONTRIBUTING.md exists.
- [ ] `bash scripts/bash/validate-package.sh` passes.
- [ ] No private logs, secrets, or project data are included.

## Adopted project

- [ ] `.agents/AGENTS.md` exists.
- [ ] `.agents/workflows/fastpatch.md` exists.
- [ ] `.agy/PHASE_STATUS.json` parses.
- [ ] `.cbmignore` exists.
- [ ] `scripts/Test-FastPatchAllowed.ps1` denies broad dirty worktrees.
- [ ] `/auditphase` is run before feature work.
