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
if (!(Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js is required." }

& node $NodeCore validate-pack --repo-root $Root
if ($LASTEXITCODE -ne 0) { throw "Companion pack validation failed." }

if ($RunRepositoryValidators) {
  $PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  foreach ($Relative in @(
    "scripts\windows\Test-HumanDocsCleanup.ps1",
    "scripts\windows\Validate-AgenticPipelinePackage.ps1",
    "scripts\windows\Test-PowerShellRuntimeContracts.ps1"
  )) {
    $ScriptPath = Join-Path $Root $Relative
    if (!(Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Required validator missing: $ScriptPath" }
    $Arguments = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$ScriptPath)
    if ($Relative -like "*Validate-AgenticPipelinePackage.ps1") { $Arguments += @("-RepoRoot",$Root,"-Strict") }
    elseif ($Relative -like "*Test-PowerShellRuntimeContracts.ps1") { $Arguments += @("-RepoRoot",$Root) }
    & $PowerShellExe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Repository validator failed: $Relative" }
  }
}

if ($PackageMode) {
  Write-Host "git diff --check skipped in package mode because release archives intentionally contain no .git metadata."
}
else {
  if (!(Test-Path -LiteralPath (Join-Path $Root ".git"))) {
    throw "RepoRoot is not a Git working tree. Use -PackageMode for extracted release-package validation: $Root"
  }

  & git -C $Root diff --check
  if ($LASTEXITCODE -ne 0) { throw "git diff --check failed." }
}
Write-Host "Companion pack v1.2.2 validation passed."
exit 0
