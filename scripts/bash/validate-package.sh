#!/usr/bin/env bash
set -euo pipefail
required=(
  README.md README.ru.md VERSION.json ECOSYSTEM_VERSION.json LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md
  docs/AGENTIC_PIPELINE_PLAYBOOK.md docs/AUDIT_CHECKLIST.md docs/PIPELINE_VERSION_MATRIX.md
  config/command-inventory.json schemas/phase-status.schema.json schemas/command-inventory.schema.json schemas/version.schema.json
  docs/companion/01_PROJECT_INSTRUCTIONS_v1.2.16.md docs/companion/00_AGENTIC_PIPELINE_INDEX_v1.2.16.md docs/companion/02_AGENT_TASK_PACK_CONTRACT_v1.2.16.md
  docs/companion/08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md docs/companion/14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md docs/companion/15_OWNER_OUTPUT_PRESENTATION.md
  schemas/companion/runtime-handshake.schema.json schemas/companion/phase-contract.schema.json schemas/companion/finding.schema.json schemas/companion/phase-result.schema.json schemas/companion/action-packet.schema.json
  evals/companion/golden_cases.json evals/companion/autonomous_convergence_cases.json scripts/companion/companion-control.cjs scripts/control-plane/autonomous-convergence.cjs tests/acceptance/autonomous-convergence-contract.cjs
  scripts/windows/companion/Test-CompanionPack-v1.2.16.ps1 scripts/windows/companion/Test-AutonomousConvergenceContracts.ps1 scripts/windows/Test-UnifiedEcosystemVersion.ps1
  scripts/bridge/companion_action_bridge.py scripts/bridge/Install-CompanionActionBridge.ps1
  integrations/companion-handoff-1.2.16/Update-AgenticContextHandoff-v1.2.16.ps1
  templates/state-profiles/new-project/PHASE_STATUS.json templates/state-profiles/adopt-existing/PHASE_STATUS.json
  templates/agy-project-base/.agents/AGENTS.md templates/agy-project-base/.agents/COMMAND_INVENTORY.json
  templates/agy-project-base/.agents/hooks/agentic_runtime_hook.cjs templates/agy-project-base/.agents/workflows/fastpatch.md
  templates/agy-project-base/scripts/Test-FastPatchAllowed.ps1 templates/agy-project-base/scripts/control-plane/action-packet.cjs
  scripts/bash/adopt-pipeline.sh scripts/windows/Initialize-AgenticProject.ps1 scripts/windows/Test-DistributionIntegrity.ps1 scripts/windows/Build-ReleasePackage.ps1
)
for f in "${required[@]}"; do [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; exit 1; }; done
if find templates/agy-project-base -type f \( -path '*/.agy/checkpoints/*' -o -name 'git-status-*' -o -name '*.bak-*' -o -name '*.log' \) | grep -q .; then
  echo 'Generated or backup artifacts found in template:' >&2
  find templates/agy-project-base -type f \( -path '*/.agy/checkpoints/*' -o -name 'git-status-*' -o -name '*.bak-*' -o -name '*.log' \) >&2
  exit 1
fi
if grep -R "C:\\Users\\Администратор\\AppData\\Local\\Programs\\codebase-memory-mcp" -n . --exclude-dir=.git --exclude='*.zip' >/tmp/ap_grep.$$ 2>/dev/null; then
  echo 'Found stale direct Codebase Memory user path' >&2; cat /tmp/ap_grep.$$ >&2; rm -f /tmp/ap_grep.$$; exit 1
fi
rm -f /tmp/ap_grep.$$
node scripts/companion/companion-control.cjs validate-pack --repo-root .
node tests/acceptance/autonomous-convergence-contract.cjs
node scripts/control-plane/action-packet.cjs --help >/dev/null 2>&1 || true
echo 'Package validation passed.'
