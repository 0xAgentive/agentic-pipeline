[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [switch]$RunRepositoryValidators,
  [switch]$PackageMode
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$NodeCore = Join-Path $Root "scripts\companion\companion-control.cjs"
if (!(Test-Path -LiteralPath $NodeCore -PathType Leaf)) { throw "Companion validator not found: $NodeCore" }
$Node = Get-Command node -ErrorAction Stop

& $Node.Source $NodeCore validate-pack --repo-root $Root
if ($LASTEXITCODE -ne 0) { throw "Companion pack validation failed." }

& $Node.Source $NodeCore test-flow-restoration --repo-root $Root
if ($LASTEXITCODE -ne 0) { throw "Flow restoration routing tests failed." }

& $Node.Source (Join-Path $Root "tests\acceptance\autonomous-convergence-contract.cjs")
if ($LASTEXITCODE -ne 0) { throw "Autonomous convergence acceptance tests failed." }

$Version = Get-Content -LiteralPath (Join-Path $Root "docs\companion\VERSION.json") -Raw | ConvertFrom-Json
if ([string]$Version.companion_version -ne "1.2.4") { throw "Unexpected Companion version: $($Version.companion_version)" }

foreach ($Required in @(
  "docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.4.md",
  "docs\companion\00_AGENTIC_PIPELINE_INDEX_v1.2.4.md",
  "docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.4.md",
  "docs\companion\14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md",
  "docs\companion\15_OWNER_OUTPUT_PRESENTATION.md"
)) {
  if (!(Test-Path -LiteralPath (Join-Path $Root $Required) -PathType Leaf)) { throw "Missing Companion 1.2.4 file: $Required" }
}

if ($RunRepositoryValidators) {
  $PowerShellExe = (Get-Command pwsh -ErrorAction Stop).Source
  foreach ($Relative in @(
    "scripts\windows\Test-HumanDocsCleanup.ps1",
    "scripts\windows\Validate-AgenticPipelinePackage.ps1",
    "scripts\windows\Test-PowerShellRuntimeContracts.ps1",
    "scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1"
  )) {
    $ScriptPath = Join-Path $Root $Relative
    if (!(Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Required validator missing: $ScriptPath" }
    $Arguments = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$ScriptPath)
    if ($Relative -like "*Validate-AgenticPipelinePackage.ps1") { $Arguments += @("-RepoRoot",$Root,"-Strict") }
    elseif ($Relative -like "*Test-PowerShellRuntimeContracts.ps1" -or $Relative -like "*Test-AutonomousConvergenceContracts.ps1") { $Arguments += @("-RepoRoot",$Root) }
    & $PowerShellExe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Repository validator failed: $Relative" }
  }
}

if ($PackageMode) {
  Write-Host "git diff --check skipped in package mode because release archives intentionally contain no .git metadata."
}
else {
  & git -C $Root diff --check
  if ($LASTEXITCODE -ne 0) { throw "git diff --check failed." }
}
Write-Host "Companion pack v1.2.4 validation passed."
exit 0
