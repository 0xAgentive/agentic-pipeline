[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$RepoRoot="$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$Apply,
  [switch]$AllowDirty,
  [switch]$SkipValidation,
  [switch]$SkipActiveWorkItemMigration,
  [string]$BackupBaseRoot="$env:USERPROFILE\Documents\antigravity\pipeline-maintenance\runtime-backups"
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Utf8NoBom=[Text.UTF8Encoding]::new($false)
$Stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$Pipeline=(Resolve-Path -LiteralPath $RepoRoot).Path
$Project=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Template=Join-Path $Pipeline 'templates\agy-project-base'
$Version=Get-Content -LiteralPath (Join-Path $Pipeline 'VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$Version.package_version-ne'1.2.8'-or[string]$Version.runtime_version-ne'1.2.8'){throw "This updater requires Pipeline 1.2.8 / runtime 1.2.8. Found $($Version.package_version) / $($Version.runtime_version)."}
foreach($CommandName in @('git','node','pwsh')){if(-not(Get-Command $CommandName -ErrorAction SilentlyContinue)){throw "Required command missing: $CommandName"}}
if(-not(Test-Path -LiteralPath $Template -PathType Container)){throw "Runtime template missing: $Template"}
$GitStatus=@();if(Test-Path -LiteralPath (Join-Path $Project '.git')){$GitStatus=@(& git -C $Project status --porcelain=v1 --untracked-files=all 2>&1);if($LASTEXITCODE-ne0){throw 'git status failed for target project.'};if($GitStatus.Count-gt0-and-not$AllowDirty){Write-Host 'Project has pre-existing changes:';$GitStatus|ForEach-Object{Write-Host $_};throw 'Use -AllowDirty after reviewing the framework-owned allowlist. Product files are never cleaned or reset.'}}
$FrameworkOwned=@(
'.agents\AGENTS.md','.agents\COMMAND_INVENTORY.json','.agents\hooks.json','.agents\hooks\agentic_runtime_hook.cjs','.agents\hooks\Test-HookContract.ps1',
'.agents\rules\05-runtime-contract.md','.agents\rules\10-pipeline-rules.md','.agents\rules\30-product-evidence-contract.md','.agents\rules\30-verification-gates.md','.agents\rules\60-v1.2-runtime-truth.md','.agents\rules\61-autonomous-audit-convergence.md','.agents\rules\62-protected-reviewer.md','.agents\rules\63-scientific-stage-firewall.md','.agents\rules\64-owner-autonomy.md',
'.agents\workflows\planonly.md','.agents\workflows\nextphase.md','.agents\workflows\auditphase.md','.agents\workflows\fixcritical.md',
'.agents\skills\audit-coverage-matrix\SKILL.md','.agents\skills\protected-reviewer\SKILL.md','.agents\skills\scientific-stage-firewall\SKILL.md',
'scripts\control-plane\autonomous-convergence.cjs','scripts\control-plane\progress-guard.cjs','scripts\control-plane\validate-findings.cjs','scripts\control-plane\validate-owner-summary.cjs','scripts\control-plane\action-packet.cjs',
'scripts\windows\companion\New-WorkItem.ps1','scripts\windows\companion\Set-WorkItemStatus.ps1','scripts\windows\companion\Write-ExecutionScope.ps1','scripts\windows\companion\Publish-RunResult.ps1','scripts\windows\companion\New-ExecutionLease.ps1','scripts\windows\companion\Test-ExecutionLease.ps1','scripts\windows\companion\Publish-AuditCoverageMatrix.ps1','scripts\windows\companion\Test-AuditCoverageMatrix.ps1','scripts\windows\companion\Register-FindingDelta.ps1','scripts\windows\companion\Publish-RepairDelta.ps1','scripts\windows\companion\Register-RepairBatch.ps1','scripts\windows\companion\New-ProtectedReviewerAttestation.ps1','scripts\windows\companion\Test-ProtectedReviewerAttestation.ps1','scripts\windows\companion\New-StageFirewall.ps1','scripts\windows\companion\Compile-ResultAuthority.ps1','scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1',
'scripts\windows\companion\Activate-ActionPacket.ps1','scripts\windows\companion\Start-WorkItemTransaction.ps1','scripts\windows\companion\Bind-ExecutionScopeTransaction.ps1','scripts\windows\companion\Register-Progress.ps1','scripts\windows\companion\Test-FindingSet.ps1','scripts\windows\companion\Validate-ControlPlaneState.ps1','scripts\windows\companion\Publish-NextAction.ps1','scripts\windows\companion\Publish-CandidateManifest.ps1','scripts\windows\companion\Migrate-ActiveWorkItemToProgressGuard.ps1'
)
$StateDefaults=@('.agy\CONVERGENCE_POLICY.json','.agy\STAGE_FIREWALL.json','.agy\PROGRESS_POLICY.json','.agy\PROGRESS_STATE.json','.agy\NEXT_ACTION.json','.agy\CANDIDATE_MANIFEST_STATUS.json')
foreach($Relative in $FrameworkOwned+$StateDefaults){$Source=Join-Path $Template $Relative;if(-not(Test-Path -LiteralPath $Source -PathType Leaf)){throw "Runtime source missing: $Relative"}}
Write-Host 'Agentic project runtime update';Write-Host "Project: $Project";Write-Host "Package/runtime: $($Version.package_version) / $($Version.runtime_version)";Write-Host "Apply: $Apply";Write-Host 'Framework-owned paths:';$FrameworkOwned|ForEach-Object{Write-Host "- $_"};Write-Host 'State defaults (create only when missing):';$StateDefaults|ForEach-Object{Write-Host "- $_"}
if(-not$Apply){Write-Host 'DRY RUN COMPLETE. No files changed.';return}
$ProjectSlug=([IO.Path]::GetFileName($Project)-replace'[^A-Za-z0-9._-]','_')
$BackupRoot=Join-Path $BackupBaseRoot (Join-Path $ProjectSlug $Stamp)
$BackupIndex=New-Object System.Collections.Generic.List[object]
$Copied=New-Object System.Collections.Generic.List[string]
$Skipped=New-Object System.Collections.Generic.List[string]
$MutationStarted=$false
function Backup-Path([string]$Relative){$Destination=Join-Path $Project $Relative;$Entry=[ordered]@{relative=$Relative;existed=(Test-Path -LiteralPath $Destination -PathType Leaf)};if($Entry.existed){$Backup=Join-Path $BackupRoot $Relative;New-Item -ItemType Directory -Force (Split-Path -Parent $Backup)|Out-Null;Copy-Item -LiteralPath $Destination -Destination $Backup -Force;$Entry.backup=$Backup}else{$Entry.backup=$null};$BackupIndex.Add([pscustomobject]$Entry)|Out-Null}
function Restore-Transaction(){foreach($Entry in @($BackupIndex|Sort-Object{$_.relative.Length}-Descending)){ $Destination=Join-Path $Project $Entry.relative;if($Entry.existed){New-Item -ItemType Directory -Force (Split-Path -Parent $Destination)|Out-Null;Copy-Item -LiteralPath $Entry.backup -Destination $Destination -Force}else{Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue}}}
try{
  foreach($Relative in $FrameworkOwned){Backup-Path $Relative;$Source=Join-Path $Template $Relative;$Destination=Join-Path $Project $Relative;New-Item -ItemType Directory -Force (Split-Path -Parent $Destination)|Out-Null;Copy-Item -LiteralPath $Source -Destination $Destination -Force;$Copied.Add($Relative)|Out-Null;$MutationStarted=$true}
  foreach($Relative in $StateDefaults){$Destination=Join-Path $Project $Relative;if(Test-Path -LiteralPath $Destination -PathType Leaf){$Skipped.Add($Relative)|Out-Null;continue};Backup-Path $Relative;$Source=Join-Path $Template $Relative;New-Item -ItemType Directory -Force (Split-Path -Parent $Destination)|Out-Null;Copy-Item -LiteralPath $Source -Destination $Destination -Force;$Copied.Add($Relative)|Out-Null;$MutationStarted=$true}
  foreach($Relative in @('.agy\INSTALLATION_MANIFEST.json','.agy\RUNTIME_UPDATE_RESULT.json','.agy\OWNER_AUTONOMY_MIGRATION_RESULT.json')){if(-not(@($BackupIndex.relative)-contains$Relative)){Backup-Path $Relative}}
  $Commit='unknown';$CommitOutput=@(& git -C $Pipeline rev-parse HEAD 2>&1);if($LASTEXITCODE-eq0){$Commit=($CommitOutput-join"`n").Trim()}
  $Metadata=[ordered]@{installed_at_utc=(Get-Date).ToUniversalTime().ToString('o');mode='runtime-update';state_profile='preserved';source_repo='agentic-pipeline';source_commit=$Commit;conflict_policy='framework-owned-overlay';copied=$Copied.ToArray();skipped=$Skipped.ToArray();backed_up=@($BackupIndex|Where-Object{$_.existed}|ForEach-Object{$_.relative});backup_root=$BackupRoot;next_command=$null}
  $MetadataPath=Join-Path ([IO.Path]::GetTempPath()) ('agentic-runtime-update-'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($MetadataPath,($Metadata|ConvertTo-Json -Depth 30),$Utf8NoBom)
  try{& node (Join-Path $Pipeline 'scripts\control-plane\write-installation-manifest.cjs') --repo-root $Pipeline --output (Join-Path $Project '.agy\INSTALLATION_MANIFEST.json') --metadata-file $MetadataPath;if($LASTEXITCODE-ne0){throw 'Installation manifest writer failed.'}}finally{Remove-Item -LiteralPath $MetadataPath -Force -ErrorAction SilentlyContinue}
  if(-not$SkipActiveWorkItemMigration){& (Join-Path $Project 'scripts\windows\companion\Migrate-ActiveWorkItemToProgressGuard.ps1') -ProjectRoot $Project -Apply;if($LASTEXITCODE-ne0){throw 'Active work-item migration failed.'}}
  if(-not$SkipValidation){& (Join-Path $Pipeline 'scripts\windows\Test-CommandInventory.ps1') -RepoRoot $Pipeline -ProjectRoot $Project -SkipDocumentationScan;if($LASTEXITCODE-ne0){throw 'Deployed command inventory validation failed.'};& (Join-Path $Project 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1') -RepoRoot $Pipeline;if($LASTEXITCODE-ne0){throw 'Autonomous convergence validation failed.'};& (Join-Path $Project '.agents\hooks\Test-HookContract.ps1') -ProjectRoot $Project;if($LASTEXITCODE-ne0){throw 'Project hook contract failed.'};& (Join-Path $Project 'scripts\windows\companion\Validate-ControlPlaneState.ps1') -ProjectRoot $Project;if($LASTEXITCODE-ne0){throw 'Control-plane state validation failed.'}}
  $Result=[ordered]@{schema_version='1.2.8';status='PASS';project_root=$Project;package_version=[string]$Version.package_version;runtime_version=[string]$Version.runtime_version;companion_version=[string]$Version.companion_version;copied=$Copied.ToArray();skipped=$Skipped.ToArray();backup_root=$BackupRoot;product_source_modified=$false;active_work_item_migrated=(-not$SkipActiveWorkItemMigration);generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
  [IO.File]::WriteAllText((Join-Path $Project '.agy\RUNTIME_UPDATE_RESULT.json'),($Result|ConvertTo-Json -Depth 30),$Utf8NoBom)
  Write-Host 'PROJECT RUNTIME 1.2.8 UPDATE COMPLETED.' -ForegroundColor Green
}catch{if($MutationStarted){Write-Warning 'Runtime update failed. Restoring the exact pre-update framework-owned files.';Restore-Transaction;Write-Warning "Rollback completed from: $BackupRoot"};throw}
