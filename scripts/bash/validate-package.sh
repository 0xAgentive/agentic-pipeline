#!/usr/bin/env bash
set -euo pipefail
required=(
  README.md README.ru.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md
  docs/AGENTIC_PIPELINE_PLAYBOOK.md docs/AUDIT_CHECKLIST.md
  templates/agy-project-base/.agents/AGENTS.md
  templates/agy-project-base/.agents/workflows/fastpatch.md
  templates/agy-project-base/.agents/workflows/codebase-map.md
  templates/agy-project-base/scripts/Test-FastPatchAllowed.ps1
  scripts/bash/adopt-pipeline.sh
  scripts/windows/Apply-AgenticPipeline-v1.1.1.ps1
)
for f in "${required[@]}"; do
  [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; exit 1; }
done
if grep -R "C:\\Users\\Администратор\\AppData\\Local\\Programs\\codebase-memory-mcp" -n . --exclude-dir=.git --exclude='*.zip' >/tmp/ap_grep.$$ 2>/dev/null; then
  echo "Found stale direct Codebase Memory user path" >&2
  cat /tmp/ap_grep.$$ >&2
  rm -f /tmp/ap_grep.$$
  exit 1
fi
rm -f /tmp/ap_grep.$$
echo "Package validation passed."
