#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 1 ]] || { echo "Usage: bash scripts/bash/publish-github.sh https://github.com/<OWNER>/<REPO>.git" >&2; exit 2; }
REMOTE="$1"
bash scripts/bash/validate-package.sh
git init
git add .
git commit -m "Initial public release of Agentic Development Pipeline" || true
git branch -M main
if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$REMOTE"; else git remote add origin "$REMOTE"; fi
git push -u origin main
