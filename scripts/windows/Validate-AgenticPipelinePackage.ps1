param([string]$RepoRoot=".", [switch]$Strict)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$m){ [void]$Errors.Add($m) }
function Has([string]$p){ Test-Path -LiteralPath (Join-Path $Root $p) }

function Files([string[]]$ext=@()){
  Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object {
      $x = $_.FullName -replace "\\","/"
      $x -notmatch "/node_modules/|/dist/|/build/|/\.git/|/\.pipeline_patch_backup/|/docs/archive/"
    } |
    Where-Object { $ext.Count -eq 0 -or ($ext -contains $_.Extension.ToLowerInvariant()) }
}

$required = @(
 "README.md","README.ru.md","VERSION.json","ECOSYSTEM_VERSION.json","SOURCE_IDENTITY.json","LICENSE","SECURITY.md","CONTRIBUTING.md","CHANGELOG.md",
 "docs/AGENTIC_PIPELINE_PLAYBOOK.md","docs/GITHUB_PUBLICATION.md","docs/PIPELINE_VERSION_MATRIX.md",
 "config/command-inventory.json","schemas/phase-status.schema.json","schemas/command-inventory.schema.json","schemas/version.schema.json",
 "docs/companion/SYSTEM_PROMPT_GPT56_COMPANION_v1.2.18.md","docs/companion/00_AGENTIC_PIPELINE_INDEX_v1.2.18.md","docs/companion/01_PROJECT_INSTRUCTIONS_v1.2.18.md","docs/companion/02_AGENT_TASK_PACK_CONTRACT_v1.2.18.md","docs/companion/14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md","docs/companion/15_OWNER_OUTPUT_PRESENTATION.md",
 "schemas/companion/runtime-handshake.schema.json","schemas/companion/phase-contract.schema.json","schemas/companion/finding.schema.json","schemas/companion/phase-result.schema.json",
 "schemas/companion/work-item.schema.json","schemas/companion/execution-scope.schema.json","schemas/companion/run-result.schema.json","schemas/companion/verification-receipt.schema.json","schemas/companion/flow-policy.schema.json","schemas/companion/execution-lease.schema.json","schemas/companion/audit-coverage-matrix.schema.json","schemas/companion/finding-set.schema.json","schemas/companion/repair-delta.schema.json","schemas/companion/convergence-budget.schema.json","schemas/companion/progress-state.schema.json","schemas/companion/next-action.schema.json","schemas/companion/candidate-manifest-status.schema.json","schemas/companion/action-packet.schema.json","schemas/companion/reviewer-attestation.schema.json","schemas/companion/stage-firewall.schema.json","schemas/companion/closure-state.schema.json","templates/agy-project-base/schemas/companion/verification-receipt.schema.json",
 "evals/companion/golden_cases.json","evals/companion/flow_restoration_cases.json","evals/companion/autonomous_convergence_cases.json","scripts/companion/companion-control.cjs","scripts/control-plane/autonomous-convergence.cjs","scripts/control-plane/progress-guard.cjs","scripts/control-plane/validate-findings.cjs","scripts/control-plane/action-packet.cjs","tests/acceptance/autonomous-convergence-contract.cjs","scripts/windows/companion/Test-CompanionPack-v1.2.18.ps1","scripts/windows/companion/Test-FlowRestorationContracts.ps1","scripts/windows/companion/Test-AutonomousConvergenceContracts.ps1",
 "scripts/windows/Test-OwnerAutonomyContracts.ps1","scripts/windows/Test-UnifiedEcosystemVersion.ps1","scripts/windows/Test-OperationalDeployment.ps1","scripts/windows/Test-KnownFailureRegressionPlaybook-v1.2.18.ps1","scripts/windows/Test-FinalizationWindowsRegressions.ps1","scripts/windows/Build-AgenticProjectRuntimeOverlay-v1.2.18.ps1","scripts/windows/Update-AgenticProjectRuntime-v1.2.18.ps1","scripts/windows/common/NativeProcess.ps1","scripts/release/Apply-CandidateOverlay.ps1","scripts/bridge/companion_action_bridge.py","scripts/bridge/Install-CompanionActionBridge.ps1","scripts/bridge/Build-CompanionActionBridgePackage-v1.2.18.ps1","templates/agy-project-base/.agents/hooks.json","templates/agy-project-base/.agents/hooks/agentic_runtime_hook.cjs","templates/agy-project-base/scripts/windows/common/NativeProcess.ps1","templates/agy-project-base/.agy/PROGRESS_POLICY.json","templates/agy-project-base/.agy/PROGRESS_STATE.json","templates/agy-project-base/.agy/NEXT_ACTION.json","templates/agy-project-base/.agy/CANDIDATE_MANIFEST_STATUS.json",
 "tests/regression/KNOWN_FAILURE_PLAYBOOK_v1.2.18.json","tests/regression/finalization-known-failure-regression.cjs","tests/acceptance/Test-CandidateOverlayEolSafety.ps1","tests/acceptance/Test-ValidationSourceImmutability.ps1","tests/acceptance/Test-RuntimeUpdaterTransaction.ps1","tests/acceptance/Test-ResultAuthorityCompilerTransaction.ps1","tests/acceptance/Test-ActionBridgeEndToEnd.ps1","tests/acceptance/Test-ActionBridgeInstallerTransaction.ps1","tests/acceptance/Test-ContextHandoffAssetBinding.ps1",
 "integrations/companion-handoff-1.2.18/Build-AgenticContextHandoffPackage-v1.2.18.ps1","integrations/companion-handoff-1.2.18/Update-AgenticContextHandoff-v1.2.18.ps1","integrations/companion-handoff-1.2.18/source/handoff.config.example.json","integrations/companion-handoff-1.2.18/source/TARGET_RUNTIME_BASELINE.json","integrations/companion-handoff-1.2.18/source/src/export_ag_handoff.py","integrations/companion-handoff-1.2.18/source/src/authority_collector.py",
  "scripts/windows/Validate-AgenticPipelinePackage.ps1","scripts/windows/Test-DistributionIntegrity.ps1","scripts/windows/Test-PowerShellRuntimeContracts.ps1",
 "scripts/windows/Test-StateProfiles.ps1","scripts/windows/Test-CommandInventory.ps1",
 "scripts/windows/Test-TemplateHygiene.ps1","scripts/windows/Test-ProjectLeakage.ps1",
 "scripts/windows/Test-FreshInstall.ps1","scripts/windows/Build-ReleasePackage.ps1",
 "scripts/windows/Initialize-AgenticProject.ps1","scripts/Test-FastPatchAllowed.ps1",
 "scripts/cbm-index-current-rpc.cjs","scripts/cbm-wrapper-smoke.cjs",
 "templates/state-profiles/new-project/PHASE_STATUS.json",
 "templates/state-profiles/adopt-existing/PHASE_STATUS.json",
 "templates/agy-project-base/.cbmignore","templates/agy-project-base/.gitignore",
 "templates/agy-project-base/.agents/AGENTS.md","templates/agy-project-base/.agents/COMMAND_INVENTORY.json",
 "templates/agy-project-base/.agents/hooks.sample.json",
 "templates/agy-project-base/.agents/hooks/Test-HookContract.ps1",
 "templates/agy-project-base/.agents/workflows/githubprepare.md",
 "templates/agy-project-base/.agents/workflows/githubsync.md",
 "templates/agy-project-base/.agy/PHASE_STATUS.json","templates/agy-project-base/.agy/FLOW_POLICY.json",
 "templates/agy-project-base/.agy/GITHUB_PROFILE.json",
 "templates/agy-project-base/scripts/github/Prepare-GitHubPackage.ps1",
 "templates/agy-project-base/scripts/github/Sync-GitHub.ps1",
 "templates/agy-project-base/scripts/windows/companion/New-WorkItem.ps1",
 "templates/agy-project-base/scripts/windows/companion/Set-WorkItemStatus.ps1",
 "templates/agy-project-base/scripts/windows/companion/Write-ExecutionScope.ps1",
 "templates/agy-project-base/scripts/windows/companion/Publish-RunResult.ps1",
 "templates/agy-project-base/scripts/control-plane/autonomous-convergence.cjs",
 "templates/agy-project-base/scripts/windows/companion/New-ExecutionLease.ps1",
 "templates/agy-project-base/scripts/windows/companion/Test-ExecutionLease.ps1",
 "templates/agy-project-base/scripts/windows/companion/Publish-AuditCoverageMatrix.ps1",
 "templates/agy-project-base/scripts/windows/companion/Test-AuditCoverageMatrix.ps1",
 "templates/agy-project-base/scripts/windows/companion/Register-FindingDelta.ps1",
 "templates/agy-project-base/scripts/windows/companion/Publish-RepairDelta.ps1",
 "templates/agy-project-base/scripts/windows/companion/Register-RepairBatch.ps1",
 "templates/agy-project-base/scripts/windows/companion/New-ProtectedReviewerAttestation.ps1",
 "templates/agy-project-base/scripts/windows/companion/Test-ProtectedReviewerAttestation.ps1",
 "templates/agy-project-base/scripts/windows/companion/New-StageFirewall.ps1",
 "templates/agy-project-base/scripts/windows/companion/Compile-ResultAuthority.ps1",
 "templates/agy-project-base/.agents/rules/61-autonomous-audit-convergence.md",
 "templates/agy-project-base/.agents/rules/62-protected-reviewer.md",
 "templates/agy-project-base/.agents/rules/63-scientific-stage-firewall.md",
 "templates/agy-project-base/.agy/CONVERGENCE_POLICY.json",
 "templates/agy-project-base/.agy/STAGE_FIREWALL.json"
)
foreach($p in $required){ if(!(Has $p)){ Add-Err "Missing required file: $p" } }

foreach($f in Files @(".json")){
  try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json | Out-Null }
  catch { Add-Err "Invalid JSON: $($f.FullName)" }
}

foreach($f in Files @(".ps1")){
  $t=$null; $e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e) | Out-Null
  if(@($e).Count -gt 0){ Add-Err "PowerShell parse error: $($f.FullName): $(@($e)[0].Message)" }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if($node){
  foreach($f in Files @(".cjs")){
    & $node.Source --check $f.FullName | Out-Null
    if($LASTEXITCODE -ne 0){ Add-Err "node --check failed: $($f.FullName)" }
  }
} elseif($Strict){ Add-Err "node not found; cannot validate .cjs syntax" }

$hookDir = Join-Path $Root "templates/agy-project-base/.agents/hooks"
if(Test-Path -LiteralPath $hookDir){
  foreach($f in Get-ChildItem -LiteralPath $hookDir -File -Filter *.ps1 -ErrorAction SilentlyContinue){
    $txt = Get-Content -LiteralPath $f.FullName -Raw
    if($txt -match "Hook contract placeholder OK"){ Add-Err "Placeholder hook script detected: $($f.FullName)" }
    if($txt -match "Write-Output\s+['""]\{\}['""]"){ Add-Err "No-op hook script detected: $($f.FullName)" }
  }
}

$cbm = Join-Path $Root "templates/agy-project-base/.cbmignore"
if(Test-Path -LiteralPath $cbm){
  $txt = Get-Content -LiteralPath $cbm -Raw
  foreach($x in @("node_modules/","dist/","build/",".git/",".agy/checkpoints/",".pipeline_patch_backup/",".codebase-memory/","coverage/",".artifacts/","*.log")){
    if($txt -notmatch [regex]::Escape($x)){ Add-Err "templates .cbmignore missing: $x" }
  }
}

$legacy = Join-Path $Root "scripts/windows/Apply-AgenticPipeline-v1.1.1.ps1"
if(Test-Path -LiteralPath $legacy){
  $t = Get-Content -LiteralPath $legacy -Raw
  $danger = '$PlaybookSrc = Join-Path $ScriptDir "agentic_pipeline_playbook_v1.1.1.md"'
  if($t.Contains($danger)){ Add-Err "Legacy installer still uses missing local playbook source path" }
  if(($t -match "agentic_pipeline_playbook_v1\.1\.1\.md") -and ($t -notmatch "docs\\AGENTIC_PIPELINE_PLAYBOOK\.md|docs/AGENTIC_PIPELINE_PLAYBOOK\.md")){
    Add-Err "Legacy installer mentions old playbook without canonical docs fallback"
  }
}


$templateRoot = Join-Path $Root "templates/agy-project-base"
if(Test-Path -LiteralPath $templateRoot){
  $generated = Get-ChildItem -LiteralPath $templateRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object {
      $rel = $_.FullName.Substring($templateRoot.Length).TrimStart("\","/") -replace "\\","/"
      $rel -match '^\.agy/checkpoints/' -or $rel -match '(^|/)(git-status|checkpoint|validation|transcript)-\d{8}'
    }
  foreach($f in $generated){ Add-Err "Generated runtime artifact in template: $($f.FullName)" }
}

foreach($f in @(Files)){
  if($f.Name -like "*.bak-*" -or $f.Name -like "*.bak-v*"){
    $rel = $f.FullName.Substring($Root.Length).TrimStart("\","/")
    if((($rel -replace "\\","/").StartsWith(".pipeline_patch_backup/")) -eq $false){
      Add-Err "Backup file must not live in repo tree: $($f.FullName)"
    }
  }
}

if($Errors.Count -gt 0){
  Write-Host "Validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}
Write-Host "Hard package validation passed."
exit 0
