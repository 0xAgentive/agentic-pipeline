#!/usr/bin/env bash
set -euo pipefail

required=(
  README.md README.ru.md VERSION.json LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md
  docs/AGENTIC_PIPELINE_PLAYBOOK.md docs/AUDIT_CHECKLIST.md docs/PIPELINE_VERSION_MATRIX.md
  config/command-inventory.json schemas/phase-status.schema.json schemas/command-inventory.schema.json schemas/version.schema.json
  templates/state-profiles/new-project/PHASE_STATUS.json
  templates/state-profiles/adopt-existing/PHASE_STATUS.json
  templates/agy-project-base/.agents/AGENTS.md
  templates/agy-project-base/.agents/COMMAND_INVENTORY.json
  templates/agy-project-base/.agents/workflows/fastpatch.md
  templates/agy-project-base/.agents/workflows/githubprepare.md
  templates/agy-project-base/.agents/workflows/githubsync.md
  templates/agy-project-base/.agents/workflows/codebase-map.md
  templates/agy-project-base/scripts/Test-FastPatchAllowed.ps1
  templates/agy-project-base/scripts/github/Prepare-GitHubPackage.ps1
  templates/agy-project-base/scripts/github/Sync-GitHub.ps1
  scripts/bash/adopt-pipeline.sh
  scripts/windows/Initialize-AgenticProject.ps1
  scripts/windows/Apply-AgenticPipeline-v1.1.1.ps1
  scripts/windows/Test-DistributionIntegrity.ps1
  scripts/windows/Test-PowerShellRuntimeContracts.ps1
  scripts/windows/Test-FreshInstall.ps1
  scripts/windows/Build-ReleasePackage.ps1
)

for f in "${required[@]}"; do
  [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; exit 1; }
done

if find templates/agy-project-base -type f \( -path '*/.agy/checkpoints/*' -o -name 'git-status-*' -o -name '*.bak-*' -o -name '*.log' \) | grep -q .; then
  echo "Generated or backup artifacts found in template:" >&2
  find templates/agy-project-base -type f \( -path '*/.agy/checkpoints/*' -o -name 'git-status-*' -o -name '*.bak-*' -o -name '*.log' \) >&2
  exit 1
fi

if grep -R "C:\\Users\\Администратор\\AppData\\Local\\Programs\\codebase-memory-mcp" -n . --exclude-dir=.git --exclude='*.zip' >/tmp/ap_grep.$$ 2>/dev/null; then
  echo "Found stale direct Codebase Memory user path" >&2
  cat /tmp/ap_grep.$$ >&2
  rm -f /tmp/ap_grep.$$
  exit 1
fi
rm -f /tmp/ap_grep.$$

echo "Package validation passed."
