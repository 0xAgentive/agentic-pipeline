#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || {
  echo "Usage: bash scripts/bash/adopt-pipeline.sh /path/to/existing/project" >&2
  exit 2
}

TARGET="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/agy-project-base"
MANIFEST_WRITER="$REPO_ROOT/scripts/control-plane/write-installation-manifest.cjs"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/.pipeline_adopt_backup/$STAMP"

[[ -d "$TARGET" ]] || {
  echo "Target does not exist: $TARGET" >&2
  exit 1
}
[[ -f "$MANIFEST_WRITER" ]] || {
  echo "Shared installation manifest writer not found: $MANIFEST_WRITER" >&2
  exit 1
}
command -v node >/dev/null 2>&1 || {
  echo "Node.js is required to write the installation manifest." >&2
  exit 1
}

if [[ -d "$TARGET/.git" ]] &&
   [[ -n "$(git -C "$TARGET" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Refusing to adopt into a dirty Git worktree: $TARGET" >&2
  exit 1
fi

mkdir -p "$BACKUP"

while IFS= read -r -d '' src; do
  rel="${src#$TEMPLATE/}"
  case "$rel" in
    .agy/PHASE_STATUS.json|.agy/AGENT_STATE.md|.agy/RECOVERY_PROMPT.md)
      continue
      ;;
  esac

  if [[ -f "$TARGET/$rel" ]]; then
    echo "KEEP existing: $rel"
  else
    mkdir -p "$(dirname "$TARGET/$rel")"
    cp -p "$src" "$TARGET/$rel"
  fi
done < <(find "$TEMPLATE" -type f -print0)

mkdir -p "$TARGET/.agy"

if [[ ! -f "$TARGET/.agy/PHASE_STATUS.json" ]]; then
  project_name="$(basename "$TARGET")"
  sed "s/<ProjectName>/${project_name//\//\\/}/g" \
    "$REPO_ROOT/templates/state-profiles/adopt-existing/PHASE_STATUS.json" \
    > "$TARGET/.agy/PHASE_STATUS.json"

  cp -p \
    "$REPO_ROOT/templates/state-profiles/adopt-existing/AGENT_STATE.md" \
    "$TARGET/.agy/AGENT_STATE.md"

  cp -p \
    "$REPO_ROOT/templates/state-profiles/adopt-existing/RECOVERY_PROMPT.md" \
    "$TARGET/.agy/RECOVERY_PROMPT.md"
else
  echo "Existing .agy state preserved."
fi

source_commit="unknown"
if [[ -d "$REPO_ROOT/.git" ]] || git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  source_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
fi

node "$MANIFEST_WRITER" \
  --repo-root "$REPO_ROOT" \
  --output "$TARGET/.agy/INSTALLATION_MANIFEST.json" \
  --mode adopt \
  --state-profile adopt-existing \
  --source-repo agentic-pipeline \
  --source-commit "$source_commit" \
  --next-command /landing

echo "Pipeline adopted into: $TARGET"
echo "Backup directory reserved at: $BACKUP"
echo "Next command: /landing"
