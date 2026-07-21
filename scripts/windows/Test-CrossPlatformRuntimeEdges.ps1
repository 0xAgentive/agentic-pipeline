[CmdletBinding()]
param(
  [string]$RepoRoot = "."
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$VersionPath = Join-Path $Root "VERSION.json"
$HandshakeSchemaPath = Join-Path $Root "schemas\companion\runtime-handshake.schema.json"

if (!(Test-Path -LiteralPath $VersionPath -PathType Leaf)) {
  throw "VERSION.json is missing: $VersionPath"
}
if (!(Test-Path -LiteralPath $HandshakeSchemaPath -PathType Leaf)) {
  throw "Runtime handshake schema is missing: $HandshakeSchemaPath"
}

$VersionInfo = (
  [System.IO.File]::ReadAllText(
    $VersionPath,
    [System.Text.Encoding]::UTF8
  ) |
    ConvertFrom-Json
)

$HandshakeSchema = (
  [System.IO.File]::ReadAllText(
    $HandshakeSchemaPath,
    [System.Text.Encoding]::UTF8
  ) |
    ConvertFrom-Json
)

$ExpectedPackageVersion = [string]$VersionInfo.package_version
$ExpectedRuntimeVersion = [string]$VersionInfo.runtime_version
$ExpectedHandshakeSchemaVersion = [string]$HandshakeSchema.properties.schema_version.const

foreach ($RequiredValue in @(
  $ExpectedPackageVersion,
  $ExpectedRuntimeVersion,
  $ExpectedHandshakeSchemaVersion
)) {
  if ([string]::IsNullOrWhiteSpace([string]$RequiredValue)) {
    throw "Candidate version metadata is incomplete."
  }
}
$TempRoot = Join-Path (
  [System.IO.Path]::GetTempPath()
) ("agentic-cross-platform-edges-" + [Guid]::NewGuid().ToString("N"))

function Invoke-Capture {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

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

function Invoke-Native {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  $Result = Invoke-Capture -FilePath $FilePath -Arguments $Arguments
  if ($Result.Code -ne 0) {
    throw "Native command failed: $FilePath $($Arguments -join ' ')`n$($Result.Text)"
  }
  return $Result
}

function Write-Utf8 {
  param([string]$Path, [string]$Text)
  $Parent = Split-Path -Parent $Path
  if ($Parent) {
    New-Item -ItemType Directory -Force $Parent | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

try {
  New-Item -ItemType Directory -Force $TempRoot | Out-Null

  $Project = Join-Path $TempRoot "default-handshake-project"
  $Initializer = Join-Path $Root "scripts\windows\Initialize-AgenticProject.ps1"
  $HandshakeScript = Join-Path $Root "scripts\windows\companion\Get-RuntimeHandshake.ps1"

  $Initialize = Invoke-Capture `
    -FilePath $HostExe `
    -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $Initializer,
      "-TargetRoot", $Project,
      "-Mode", "New",
      "-ConflictPolicy", "Fail",
      "-RepoRoot", $Root,
      "-Apply"
    )

  if ($Initialize.Code -ne 0) {
    throw "Default-handshake fixture installation failed.`n$($Initialize.Text)"
  }

  foreach ($GitArgs in @(
    @("-C", $Project, "init", "--quiet"),
    @("-C", $Project, "config", "user.name", "Cross Platform Fixture"),
    @("-C", $Project, "config", "user.email", "fixture@example.invalid"),
    @("-C", $Project, "add", "."),
    @("-C", $Project, "commit", "-m", "fixture", "--quiet")
  )) {
    Invoke-Native -FilePath "git" -Arguments $GitArgs | Out-Null
  }

  $EnvironmentSnapshot = @{}
  foreach ($Name in @("AGENTIC_PIPELINE_TEMP", "TEMP", "TMP", "TMPDIR")) {
    $EnvironmentSnapshot[$Name] = [Environment]::GetEnvironmentVariable(
      $Name,
      [EnvironmentVariableTarget]::Process
    )
    [Environment]::SetEnvironmentVariable(
      $Name,
      $null,
      [EnvironmentVariableTarget]::Process
    )
  }

  try {
    $HandshakeResult = Invoke-Capture `
      -FilePath $HostExe `
      -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $HandshakeScript,
        "-ProjectRoot", $Project,
        "-PipelineRoot", $Root
      )
  }
  finally {
    foreach ($Name in @("AGENTIC_PIPELINE_TEMP", "TEMP", "TMP", "TMPDIR")) {
      [Environment]::SetEnvironmentVariable(
        $Name,
        $EnvironmentSnapshot[$Name],
        [EnvironmentVariableTarget]::Process
      )
    }
  }

  if ($HandshakeResult.Code -ne 0) {
    throw "Default handshake failed without AGENTIC_PIPELINE_TEMP/TEMP/TMP/TMPDIR.`n$($HandshakeResult.Text)"
  }

  $PathMatch = [regex]::Match(
    $HandshakeResult.Text,
    '(?m)^Runtime handshake written:\s*(?<path>.+?)\s*$'
  )

  if (!$PathMatch.Success) {
    throw "Default handshake output path was not reported.`n$($HandshakeResult.Text)"
  }

  $GeneratedHandshakePath = $PathMatch.Groups["path"].Value.Trim()

  if (!(Test-Path -LiteralPath $GeneratedHandshakePath -PathType Leaf)) {
    throw "Default handshake file was not created: $GeneratedHandshakePath"
  }

  if (![System.IO.Path]::IsPathRooted($GeneratedHandshakePath)) {
    throw "Default handshake output path is not absolute: $GeneratedHandshakePath"
  }

  $GeneratedHandshakeFullPath = [System.IO.Path]::GetFullPath(
    $GeneratedHandshakePath
  )
  $GeneratedHandshakeParent = [System.IO.Path]::GetDirectoryName(
    $GeneratedHandshakeFullPath
  )

  if ([string]::IsNullOrWhiteSpace($GeneratedHandshakeParent) -or
      ![System.IO.Directory]::Exists($GeneratedHandshakeParent)) {
    throw "Default handshake output directory is not usable: $GeneratedHandshakeParent"
  }

  $TrimSeparators = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $ProjectFullPath = [System.IO.Path]::GetFullPath($Project).TrimEnd(
    $TrimSeparators
  )
  $ProjectPrefix = $ProjectFullPath + [System.IO.Path]::DirectorySeparatorChar
  $PathComparison = if (
    [System.Environment]::OSVersion.Platform -eq
    [System.PlatformID]::Win32NT
  ) {
    [System.StringComparison]::OrdinalIgnoreCase
  }
  else {
    [System.StringComparison]::Ordinal
  }

  if ($GeneratedHandshakeFullPath.StartsWith($ProjectPrefix, $PathComparison)) {
    throw "Default handshake output was written inside the project: $GeneratedHandshakeFullPath"
  }

  $ProjectStatus = Invoke-Capture `
    -FilePath "git" `
    -Arguments @(
      "-C", $Project,
      "status", "--porcelain=v1", "--untracked-files=all"
    )

  if ($ProjectStatus.Code -ne 0 -or
      ![string]::IsNullOrWhiteSpace($ProjectStatus.Text)) {
    throw "Default handshake dirtied the fixture project.`n$($ProjectStatus.Text)"
  }

  $Handshake = (
    [System.IO.File]::ReadAllText(
      $GeneratedHandshakePath,
      [System.Text.Encoding]::UTF8
    ) |
      ConvertFrom-Json
  )

  if ($Handshake.schema_version -ne $ExpectedHandshakeSchemaVersion -or
      $Handshake.runtime_version -ne $ExpectedRuntimeVersion -or
      $Handshake.routing_valid -ne $true) {
    throw (
      "Default handshake content is invalid. " +
      "Expected schema=$ExpectedHandshakeSchemaVersion runtime=$ExpectedRuntimeVersion routing_valid=True; " +
      "actual schema=$($Handshake.schema_version) runtime=$($Handshake.runtime_version) routing_valid=$($Handshake.routing_valid)."
    )
  }

  Remove-Item -LiteralPath $GeneratedHandshakePath -Force
  Write-Host "Default handshake temp-path regression passed."

  $Bash = Get-Command bash -ErrorAction SilentlyContinue
  $RunningOnLinux = (
    $PSVersionTable.PSVersion.Major -ge 6 -and
    $IsLinux
  )

  if (!$RunningOnLinux -or $null -eq $Bash) {
    Write-Host "Bash linked-worktree adoption regression skipped on this host."
  }
  else {
    $BaseRepo = Join-Path $TempRoot "bash-base"
    $LinkedTarget = Join-Path $TempRoot "bash-linked-target"
    $BranchName = "linked-" + [Guid]::NewGuid().ToString("N")
    $AdoptScript = Join-Path $Root "scripts\bash\adopt-pipeline.sh"

    New-Item -ItemType Directory -Force $BaseRepo | Out-Null
    Write-Utf8 -Path (Join-Path $BaseRepo "README.md") -Text "# Base fixture`n"

    foreach ($GitArgs in @(
      @("-C", $BaseRepo, "init", "--quiet"),
      @("-C", $BaseRepo, "config", "user.name", "Cross Platform Fixture"),
      @("-C", $BaseRepo, "config", "user.email", "fixture@example.invalid"),
      @("-C", $BaseRepo, "add", "."),
      @("-C", $BaseRepo, "commit", "-m", "fixture", "--quiet"),
      @("-C", $BaseRepo, "worktree", "add", "-b", $BranchName, $LinkedTarget)
    )) {
      Invoke-Native -FilePath "git" -Arguments $GitArgs | Out-Null
    }

    Write-Utf8 -Path (Join-Path $LinkedTarget "DIRTY.txt") -Text "dirty`n"

    $DirtyAdoption = Invoke-Capture `
      -FilePath $Bash.Source `
      -Arguments @($AdoptScript, $LinkedTarget)

    if ($DirtyAdoption.Code -eq 0) {
      throw "Dirty linked Git worktree was incorrectly accepted by Bash adoption."
    }

    if (Test-Path -LiteralPath (
      Join-Path $LinkedTarget ".agy\INSTALLATION_MANIFEST.json"
    )) {
      throw "Dirty linked-worktree rejection wrote an installation manifest."
    }

    Remove-Item -LiteralPath (Join-Path $LinkedTarget "DIRTY.txt") -Force

    $CleanAdoption = Invoke-Capture `
      -FilePath $Bash.Source `
      -Arguments @($AdoptScript, $LinkedTarget)

    if ($CleanAdoption.Code -ne 0) {
      throw "Clean linked Git worktree adoption failed.`n$($CleanAdoption.Text)"
    }

    $ManifestPath = Join-Path $LinkedTarget ".agy\INSTALLATION_MANIFEST.json"
    if (!(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      throw "Clean linked-worktree adoption did not write a manifest."
    }

    $Manifest = (
      [System.IO.File]::ReadAllText(
        $ManifestPath,
        [System.Text.Encoding]::UTF8
      ) |
        ConvertFrom-Json
    )

    if ($Manifest.package_version -ne $ExpectedPackageVersion -or
        $Manifest.runtime_version -ne $ExpectedRuntimeVersion -or
        $Manifest.mode -ne "adopt") {
      throw (
        "Clean linked-worktree adoption manifest is invalid. " +
        "Expected package=$ExpectedPackageVersion runtime=$ExpectedRuntimeVersion mode=adopt; " +
        "actual package=$($Manifest.package_version) runtime=$($Manifest.runtime_version) mode=$($Manifest.mode)."
      )
    }

    Write-Host "Bash linked-worktree adoption regression passed."
  }

  Write-Host "Cross-platform runtime edge validation passed."
  exit 0
}
finally {
  if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}