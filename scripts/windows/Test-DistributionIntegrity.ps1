param(
  [string]$RepoRoot = ".",
  [switch]$PackageMode
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path

function Invoke-Test {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Path,
    [string[]]$ArgumentList = @()
  )

  Write-Host "[$Name]"

  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $HostExe -NoProfile -ExecutionPolicy Bypass -File $Path @ArgumentList 2>&1 |
      ForEach-Object { Write-Host $_ }
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }

  if ($Code -ne 0) { throw "$Name failed with exit code $Code" }
}

Invoke-Test -Name 'companion pack and golden evals' -Path (Join-Path $Root 'scripts\windows\companion\Test-CompanionPack-v1.2.2.ps1') -ArgumentList @('-RepoRoot',$Root)
Invoke-Test -Name 'PowerShell runtime contracts' -Path (Join-Path $Root 'scripts\windows\Test-PowerShellRuntimeContracts.ps1') -ArgumentList @('-RepoRoot',$Root)
Invoke-Test -Name 'state profiles' -Path (Join-Path $Root 'scripts\windows\Test-StateProfiles.ps1') -ArgumentList @('-RepoRoot',$Root)
Invoke-Test -Name 'command inventory' -Path (Join-Path $Root 'scripts\windows\Test-CommandInventory.ps1') -ArgumentList @('-RepoRoot',$Root)
Invoke-Test -Name 'template hygiene' -Path (Join-Path $Root 'scripts\windows\Test-TemplateHygiene.ps1') -ArgumentList @('-RepoRoot',$Root)
Invoke-Test -Name 'project leakage' -Path (Join-Path $Root 'scripts\windows\Test-ProjectLeakage.ps1') -ArgumentList @('-RepoRoot',$Root)
Invoke-Test -Name 'fresh install' -Path (Join-Path $Root 'scripts\windows\Test-FreshInstall.ps1') -ArgumentList @('-RepoRoot',$Root)

foreach ($Required in @('VERSION.json','scripts\windows\Build-ReleasePackage.ps1','config\command-inventory.json')) {
  if (!(Test-Path -LiteralPath (Join-Path $Root $Required))) { throw "Distribution file missing: $Required" }
}

$VersionInfo = Get-Content -LiteralPath (Join-Path $Root 'VERSION.json') -Raw | ConvertFrom-Json
foreach ($Field in @('package_version','playbook_version','runtime_version','companion_version','status')) {
  if (!($VersionInfo.PSObject.Properties.Name -contains $Field)) { throw "VERSION.json missing field: $Field" }
}
if ($VersionInfo.status -notin @('development','candidate','stable','deprecated')) { throw "VERSION.json status is invalid" }

if ($PackageMode) {
  foreach ($Forbidden in @('.git','.pipeline_patch_backup','.artifacts')) {
    if (Test-Path -LiteralPath (Join-Path $Root $Forbidden)) { throw "Forbidden release-package path present: $Forbidden" }
  }
}

Write-Host "Distribution-integrity validation passed."
exit 0
