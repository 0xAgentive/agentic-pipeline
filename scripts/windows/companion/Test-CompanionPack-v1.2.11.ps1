[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$RunRepositoryValidators,
  [switch]$PackageMode,
  [ValidateSet('strict', 'advisory', 'skip')]
  [string]$WorkingTreeWhitespacePolicy = 'strict'
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $RepoRoot).Path
$Failures=New-Object System.Collections.Generic.List[string]
function Add-Failure([string]$Message){[void]$Failures.Add($Message)}
$NodeCore=Join-Path $Root 'scripts\companion\companion-control.cjs'
if(!(Test-Path -LiteralPath $NodeCore -PathType Leaf)){Add-Failure "Companion validator not found: $NodeCore"}
else{
 $Node=Get-Command node -ErrorAction Stop
 & $Node.Source $NodeCore validate-pack --repo-root $Root
 if($LASTEXITCODE-ne0){Add-Failure 'Companion pack validation failed.'}
 & $Node.Source $NodeCore test-flow-restoration --repo-root $Root
 if($LASTEXITCODE-ne0){Add-Failure 'Flow restoration routing tests failed.'}
 & $Node.Source (Join-Path $Root 'tests\acceptance\autonomous-convergence-contract.cjs')
 if($LASTEXITCODE-ne0){Add-Failure 'Autonomous convergence acceptance tests failed.'}
}
try{
 $Version=Get-Content -LiteralPath (Join-Path $Root 'docs\companion\VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if([string]$Version.companion_version-ne'1.2.11'-or[string]$Version.ecosystem_version-ne'1.2.11'){Add-Failure "Unexpected Companion version: $($Version.companion_version)"}
}catch{Add-Failure "Invalid Companion VERSION.json: $($_.Exception.Message)"}
foreach($Required in @(
 'docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.11.md','docs\companion\00_AGENTIC_PIPELINE_INDEX_v1.2.11.md','docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.11.md',
 'docs\companion\08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md','docs\companion\14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md','docs\companion\15_OWNER_OUTPUT_PRESENTATION.md'
)){if(!(Test-Path -LiteralPath (Join-Path $Root $Required)-PathType Leaf)){Add-Failure "Missing Companion 1.2.11 file: $Required"}}
$TextPath=Join-Path $Root 'docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.11.md'
$Text=if(Test-Path -LiteralPath $TextPath){Get-Content -LiteralPath $TextPath -Raw -Encoding UTF8}else{''}
foreach($Marker in @('Work-item model','Blocker materiality','A current handshake remains the preferred source','Plain-language chat output','AGENTIC_ACTION_PACKET_<project>_<timestamp>.json','Automatic continuation')){if($Text-notmatch[regex]::Escape($Marker)){Add-Failure "Companion contract marker missing: $Marker"}}
$TaskPath=Join-Path $Root 'docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.11.md'
$Task=if(Test-Path -LiteralPath $TaskPath){Get-Content -LiteralPath $TaskPath -Raw -Encoding UTF8}else{''}
foreach($Marker in @('Agent Task Pack Contract v1.2.11','Executor discovery','Completion','owner_interaction_policy')){if($Task-notmatch[regex]::Escape($Marker)){Add-Failure "Task contract marker missing: $Marker"}}
$OwnerFiles=Get-ChildItem -LiteralPath (Join-Path $Root 'docs\companion') -File -ErrorAction SilentlyContinue|Where-Object{$_.Name-notmatch'^(COMPANION_CHANGELOG|README)'}
$ForbiddenPatterns=@(
 'repair_batch_limit','repair_batches_used','initial_audits_used','final_audits_used','HARD_STOP_REPAIR_BUDGET','(?i)repair\s+batch\s+\d+\s*/\s*\d+','(?i)audit\s+budget','(?i)authorize\s+(?:an?\s+)?(?:extra|additional|another)\s+repair'
)
foreach($File in $OwnerFiles){$Content=Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8;foreach($Pattern in $ForbiddenPatterns){if($Content-match$Pattern){Add-Failure "Owner-facing Companion file exposes internal iteration control: $($File.Name) pattern=$Pattern"}}}
foreach($Section in @('Что происходит','Что уже сделано','Что будет дальше','Нужно ли что-то от владельца')){if($Text-notmatch[regex]::Escape($Section)){Add-Failure "Plain-language section missing: $Section"}}
if($RunRepositoryValidators){
 $PowerShellExe=(Get-Command pwsh -ErrorAction Stop).Source
 foreach($Relative in @('scripts\windows\Test-HumanDocsCleanup.ps1','scripts\windows\Validate-AgenticPipelinePackage.ps1','scripts\windows\Test-PowerShellRuntimeContracts.ps1','scripts\windows\Test-UnifiedEcosystemVersion.ps1','scripts\windows\Test-OwnerAutonomyContracts.ps1','scripts\windows\Test-KnownFailureRegressionPlaybook-v1.2.11.ps1')){
  $ScriptPath=Join-Path $Root $Relative
  if(!(Test-Path -LiteralPath $ScriptPath -PathType Leaf)){Add-Failure "Required validator missing: $ScriptPath";continue}
  $Arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-RepoRoot',$Root)
  if($Relative-like'*Validate-AgenticPipelinePackage.ps1'){$Arguments+=@('-Strict')}
  & $PowerShellExe @Arguments
  if($LASTEXITCODE-ne0){Add-Failure "Repository validator failed: $Relative"}
 }
}
if (-not $PackageMode -and $WorkingTreeWhitespacePolicy -ne 'skip') {
  $FullDiffOutput = @(& git -C $Root diff --check 2>&1)
  $FullDiffExitCode = $LASTEXITCODE

  if ($FullDiffExitCode -ne 0) {
    if ($WorkingTreeWhitespacePolicy -eq 'advisory') {
      $CriticalDiffOutput = @(
        & git -C $Root diff --check -- . ':(exclude,glob)**/*.md' 2>&1
      )
      $CriticalDiffExitCode = $LASTEXITCODE

      if ($CriticalDiffExitCode -ne 0) {
        Add-Failure ('git diff --check found non-documentation whitespace errors: ' + ($CriticalDiffOutput -join ' | '))
      }
      else {
        Write-Warning ('Documentation-only whitespace issues are advisory in operational mode: ' + ($FullDiffOutput -join ' | '))
      }
    }
    else {
      Add-Failure ('git diff --check failed: ' + ($FullDiffOutput -join ' | '))
    }
  }
}
if($Failures.Count-gt0){Write-Host 'Companion pack validation failed:';$Failures|Sort-Object -Unique|ForEach-Object{Write-Host "- $_"};exit 1}
Write-Host 'Companion pack 1.2.11 validation passed.'
exit 0
