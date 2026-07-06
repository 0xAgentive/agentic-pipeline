#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 1 ]] || { echo "Usage: bash scripts/bash/adopt-pipeline.sh /path/to/existing/project" >&2; exit 2; }
TARGET="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/agy-project-base"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/.pipeline_adopt_backup/$STAMP"
[[ -d "$TARGET" ]] || { echo "Target does not exist: $TARGET" >&2; exit 1; }
mkdir -p "$BACKUP"
copy_with_backup(){ local src="$1" dst="$2"; mkdir -p "$(dirname "$dst")"; if [[ -f "$dst" ]]; then local rel="${dst#$TARGET/}"; mkdir -p "$BACKUP/$(dirname "$rel")"; cp -p "$dst" "$BACKUP/$rel"; fi; cp -p "$src" "$dst"; }
while IFS= read -r -d '' src; do rel="${src#$TEMPLATE/}"; copy_with_backup "$src" "$TARGET/$rel"; done < <(find "$TEMPLATE" -type f -print0)
mkdir -p "$TARGET/docs" "$TARGET/.agy"
copy_with_backup "$REPO_ROOT/docs/AGENTIC_PIPELINE_PLAYBOOK.md" "$TARGET/docs/AGENTIC_PIPELINE_PLAYBOOK.md"
[[ -f "$TARGET/.agy/EVIDENCE_LOG.md" ]] || printf '# EVIDENCE_LOG\n\nAppend-only pipeline evidence log.\n' > "$TARGET/.agy/EVIDENCE_LOG.md"
cat >> "$TARGET/.agy/EVIDENCE_LOG.md" <<EOT

## $(date -u +%Y-%m-%dT%H:%M:%SZ) — pipeline adopted in place

Next required command: /landing
EOT
cat > "$TARGET/.agy/PHASE_STATUS.json" <<EOT
{"project_name":"$(basename "$TARGET")","current_policy":"one_phase_only","batch_allowed":false,"project_status":"pipeline_adopted_needs_landing","next_required_command":"/landing"}
EOT
echo "Pipeline adopted into: $TARGET"
echo "Backup: $BACKUP"
echo "Next Antigravity command: /landing"
