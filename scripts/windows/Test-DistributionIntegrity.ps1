[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [switch]$PackageMode,
  [ValidateSet('operational', 'strict')][string]$Profile = 'operational'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$CoreFailures = New-Object System.Collections.Generic.List[string]
$AdvisoryFailures = New-Object System.Collections.Generic.List[string]
$Passes = New-Object System.Collections.Generic.List[string]

function Invoke-Validator {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [string[]]$ArgumentList = @(),
    [ValidateSet('core', 'advisory')][string]$Severity = 'core'
  )

  Write-Host "[$Name]"
  $Path = Join-Path $Root $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $Message = "Missing validator: $RelativePath"
    if ($Severity -eq 'core') { [void]$CoreFailures.Add($Message) } else { [void]$AdvisoryFailures.Add($Message) }
    return
  }

  $PreviousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $HostExe -NoProfile -ExecutionPolicy Bypass -File $Path @ArgumentList 2>&1 |
      ForEach-Object { Write-Host $_ }
    $ExitCode = $LASTEXITCODE
  }
  catch {
    Write-Host $_
    $ExitCode = 1
  }
  finally {
    $ErrorActionPreference = $PreviousPreference
  }

  if ($ExitCode -eq 0) {
    [void]$Passes.Add($Name)
    return
  }

  $Message = "$Name failed with exit code $ExitCode"
  if ($Severity -eq 'core') {
    [void]$CoreFailures.Add($Message)
  }
  else {
    [void]$AdvisoryFailures.Add($Message)
  }
}

$CompanionArguments = @('-RepoRoot', $Root)
if ($PackageMode) {
  $CompanionArguments += '-PackageMode'
}
elseif ($Profile -eq 'operational') {
  $CompanionArguments += @('-WorkingTreeWhitespacePolicy', 'advisory')
}
else {
  $CompanionArguments += @('-WorkingTreeWhitespacePolicy', 'strict')
}

$CoreTests = @(
  [pscustomobject]@{ Name = 'companion pack and golden evals'; Path = 'scripts\windows\companion\Test-CompanionPack-v1.2.9.ps1'; Args = $CompanionArguments },
  [pscustomobject]@{ Name = 'flow restoration contracts'; Path = 'scripts\windows\companion\Test-FlowRestorationContracts.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'autonomous convergence contracts'; Path = 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'PowerShell runtime contracts'; Path = 'scripts\windows\Test-PowerShellRuntimeContracts.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'state profiles'; Path = 'scripts\windows\Test-StateProfiles.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'command inventory'; Path = 'scripts\windows\Test-CommandInventory.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'fresh install'; Path = 'scripts\windows\Test-FreshInstall.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'owner autonomy'; Path = 'scripts\windows\Test-OwnerAutonomyContracts.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'unified ecosystem version'; Path = 'scripts\windows\Test-UnifiedEcosystemVersion.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'progress-guard migration compatibility'; Path = 'tests\acceptance\Test-ProgressGuardMigrationCompatibility.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'runtime updater transaction'; Path = 'tests\acceptance\Test-RuntimeUpdaterTransaction.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'operational deployment'; Path = 'scripts\windows\Test-OperationalDeployment.ps1'; Args = @('-RepoRoot', $Root) }
)

$AdvisoryTests = @(
  [pscustomobject]@{ Name = 'known failure regression playbook'; Path = 'scripts\windows\Test-KnownFailureRegressionPlaybook-v1.2.9.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'template hygiene'; Path = 'scripts\windows\Test-TemplateHygiene.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'project leakage'; Path = 'scripts\windows\Test-ProjectLeakage.ps1'; Args = @('-RepoRoot', $Root) },
  [pscustomobject]@{ Name = 'cross-platform runtime edges'; Path = 'scripts\windows\Test-CrossPlatformRuntimeEdges.ps1'; Args = @('-RepoRoot', $Root) }
)

foreach ($Test in $CoreTests) {
  Invoke-Validator -Name $Test.Name -RelativePath $Test.Path -ArgumentList $Test.Args -Severity 'core'
}
foreach ($Test in $AdvisoryTests) {
  Invoke-Validator -Name $Test.Name -RelativePath $Test.Path -ArgumentList $Test.Args -Severity 'advisory'
}

foreach ($Required in @('VERSION.json', 'scripts\windows\Build-ReleasePackage.ps1', 'config\command-inventory.json')) {
  if (-not (Test-Path -LiteralPath (Join-Path $Root $Required))) {
    [void]$CoreFailures.Add("Distribution file missing: $Required")
  }
}

try {
  $VersionInfo = Get-Content -LiteralPath (Join-Path $Root 'VERSION.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($Field in @('package_version', 'playbook_version', 'runtime_version', 'companion_version', 'status')) {
    if (-not ($VersionInfo.PSObject.Properties.Name -contains $Field)) {
      [void]$CoreFailures.Add("VERSION.json missing field: $Field")
    }
  }
  if ([string]$VersionInfo.status -notin @('development', 'candidate', 'stable', 'deprecated')) {
    [void]$CoreFailures.Add('VERSION.json status is invalid')
  }
}
catch {
  [void]$CoreFailures.Add("Invalid VERSION.json: $($_.Exception.Message)")
}

if ($PackageMode) {
  foreach ($Forbidden in @('.git', '.pipeline_patch_backup', '.artifacts')) {
    if (Test-Path -LiteralPath (Join-Path $Root $Forbidden)) {
      [void]$CoreFailures.Add("Forbidden release-package path present: $Forbidden")
    }
  }
}

if ($AdvisoryFailures.Count -gt 0) {
  Write-Host 'Distribution advisory warnings:'
  $AdvisoryFailures | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
}

if ($CoreFailures.Count -gt 0) {
  Write-Host 'Distribution core validation failed:'
  $CoreFailures | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

if ($Profile -eq 'strict' -and $AdvisoryFailures.Count -gt 0) {
  Write-Host 'Strict distribution validation failed because advisory checks did not pass.'
  exit 1
}

Write-Host "Distribution-integrity validation passed. Core=$($CoreTests.Count); advisory_warnings=$($AdvisoryFailures.Count); profile=$Profile"
exit 0
