# Package Manifest

The canonical release package is built by:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Build-ReleasePackage.ps1 -RepoRoot .
```

The builder uses the tracked Git tree, not a ZIP of the working directory. It produces:

```text
.artifacts/releases/<version>/
  agentic-pipeline-<version>.zip
  ARTIFACT_MANIFEST.json
  PACKAGE_CONTENTS.json
  SHA256SUMS
  validation.log
```

The archive is extracted to a temporary directory and validated again. `.git`, `.pipeline_patch_backup`, local/untracked files and ignored files are excluded by construction.

The distribution-integrity suite also rejects PowerShell scripts that shadow or assign automatic variables such as `$args`, because these collisions can silently drop native command arguments.
