[CmdletBinding()]
param(
  [string]$RepoRoot = ".",
  [string]$PowerShellExecutable = "",
  [switch]$SkipBash
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Capture {
  param([string]$FilePath, [string[]]$Arguments)
  $OldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $Output = @(& $FilePath @Arguments 2>&1)
    $Code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $OldPreference
  }
  [pscustomobject]@{
    Code = [int]$Code
    Text = ([object[]]$Output -join "`n")
  }
}

function Assert-Equal {
  param([object]$Actual, [object]$Expected, [string]$Message)
  if ([string]$Actual -ne [string]$Expected) {
    throw "$Message Expected=$Expected Actual=$Actual"
  }
}

function Read-Json {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Assert-Manifest {
  param(
    [object]$Manifest,
    [object]$Version,
    [string]$ExpectedCommit,
    [string]$Mode
  )

  Assert-Equal -Actual $Manifest.package_version -Expected $Version.package_version -Message "package_version mismatch."
  Assert-Equal -Actual $Manifest.runtime_version -Expected $Version.runtime_version -Message "runtime_version mismatch."
  Assert-Equal -Actual $Manifest.playbook_version -Expected $Version.playbook_version -Message "playbook_version mismatch."
  Assert-Equal -Actual $Manifest.companion_version -Expected $Version.companion_version -Message "companion_version mismatch."
  Assert-Equal -Actual $Manifest.source_commit -Expected $ExpectedCommit -Message "source_commit mismatch."
  Assert-Equal -Actual $Manifest.source_repo -Expected "agentic-pipeline" -Message "source_repo mismatch."
  Assert-Equal -Actual $Manifest.mode -Expected $Mode -Message "mode mismatch."

  foreach ($Required in @("state_profile", "installed_at_utc")) {
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.$Required)) {
      throw "Manifest field missing: $Required"
    }
  }
}

$ResolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
$VersionPath = Join-Path $ResolvedRepo "VERSION.json"
$WindowsInstaller = Join-Path $ResolvedRepo "scripts\windows\Initialize-AgenticProject.ps1"
$BashInstaller = Join-Path $ResolvedRepo "scripts\bash\adopt-pipeline.sh"
$ManifestWriter = Join-Path $ResolvedRepo "scripts\control-plane\write-installation-manifest.cjs"

foreach ($Required in @($VersionPath, $WindowsInstaller, $BashInstaller, $ManifestWriter)) {
  if (!(Test-Path -LiteralPath $Required -PathType Leaf)) {
    throw "Required file missing: $Required"
  }
}

$Version = Read-Json -Path $VersionPath
Assert-Equal -Actual $Version.package_version -Expected "1.2.5" -Message "Acceptance requires package 1.2.5 candidate."
Assert-Equal -Actual $Version.runtime_version -Expected "1.2.2" -Message "Acceptance requires runtime 1.2.2."
Assert-Equal -Actual $Version.companion_version -Expected "1.2.3" -Message "Companion version changed unexpectedly."

$WindowsInstallerText = [System.IO.File]::ReadAllText($WindowsInstaller, [System.Text.Encoding]::UTF8)
$BashInstallerText = [System.IO.File]::ReadAllText($BashInstaller, [System.Text.Encoding]::UTF8)
$ManifestWriterText = [System.IO.File]::ReadAllText($ManifestWriter, [System.Text.Encoding]::UTF8)

foreach ($InstallerContract in @(
  @{ Name = "Windows installer"; Text = $WindowsInstallerText },
  @{ Name = "Bash installer"; Text = $BashInstallerText }
)) {
  if (!$InstallerContract.Text.Contains("write-installation-manifest.cjs")) {
    throw "$($InstallerContract.Name) must invoke the shared manifest writer."
  }
  foreach ($ForbiddenLiteral in @('"1.2.5"', '"1.2.2"', '"1.2.3"')) {
    if ($InstallerContract.Text.Contains($ForbiddenLiteral)) {
      throw "$($InstallerContract.Name) hardcodes release version literal $ForbiddenLiteral."
    }
  }
}

if (!$ManifestWriterText.Contains("VERSION.json")) {
  throw "Shared manifest writer must read VERSION.json."
}
foreach ($ForbiddenLiteral in @('"1.2.5"', '"1.2.2"', '"1.2.3"')) {
  if ($ManifestWriterText.Contains($ForbiddenLiteral)) {
    throw "Shared manifest writer hardcodes release version literal $ForbiddenLiteral."
  }
}

$RepoHeadResult = Invoke-Capture -FilePath "git" -Arguments @("-C", $ResolvedRepo, "rev-parse", "HEAD")
if ($RepoHeadResult.Code -ne 0) { throw "Cannot resolve repository HEAD." }
$RepoHead = $RepoHeadResult.Text.Trim()

if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
  $PowerShellExecutable = (Get-Command pwsh -ErrorAction Stop).Source
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-installer-acceptance-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $TempRoot | Out-Null

try {
  $WindowsTarget = Join-Path $TempRoot "windows-new-project"
  $WindowsResult = Invoke-Capture -FilePath $PowerShellExecutable -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $WindowsInstaller,
    "-TargetRoot", $WindowsTarget,
    "-Mode", "New",
    "-ConflictPolicy", "Fail",
    "-RepoRoot", $ResolvedRepo,
    "-Apply"
  )

  if ($WindowsResult.Code -ne 0) {
    throw "Windows initializer failed. Output=$($WindowsResult.Text)"
  }

  $WindowsManifest = Read-Json -Path (Join-Path $WindowsTarget ".agy\INSTALLATION_MANIFEST.json")
  Assert-Manifest -Manifest $WindowsManifest -Version $Version -ExpectedCommit $RepoHead -Mode "new"

  if (!$SkipBash) {
    $BashCommand = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -eq $BashCommand) {
      Write-Host "Bash installer acceptance skipped locally: bash unavailable."
    }
    else {
      $BashTarget = Join-Path $TempRoot "bash-adopt-project"
      New-Item -ItemType Directory -Force $BashTarget | Out-Null
      [System.IO.File]::WriteAllText((Join-Path $BashTarget "README.md"), "# Bash fixture`n", $Utf8NoBom)

      foreach ($Args in @(
        @("-C", $BashTarget, "init", "--quiet"),
        @("-C", $BashTarget, "config", "user.name", "Acceptance Fixture"),
        @("-C", $BashTarget, "config", "user.email", "fixture@example.invalid"),
        @("-C", $BashTarget, "add", "."),
        @("-C", $BashTarget, "commit", "-m", "fixture", "--quiet")
      )) {
        $GitResult = Invoke-Capture -FilePath "git" -Arguments $Args
        if ($GitResult.Code -ne 0) { throw "Bash fixture Git setup failed. Output=$($GitResult.Text)" }
      }

      $BashResult = Invoke-Capture -FilePath $BashCommand.Source -Arguments @($BashInstaller, $BashTarget)
      if ($BashResult.Code -ne 0) {
        throw "Bash installer failed. Output=$($BashResult.Text)"
      }

      $BashManifest = Read-Json -Path (Join-Path $BashTarget ".agy\INSTALLATION_MANIFEST.json")
      Assert-Manifest -Manifest $BashManifest -Version $Version -ExpectedCommit $RepoHead -Mode "adopt"
    }
  }
}
finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Installation manifest acceptance passed." -ForegroundColor Green
exit 0
