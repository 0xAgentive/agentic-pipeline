[CmdletBinding()]
param(
  [string]$RepoRoot = "."
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
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
  $RunningOnLinux = (
    $PSVersionTable.PSVersion.Major -ge 6 -and
    $IsLinux
  )
  $ControlledTemp = Join-Path $TempRoot "controlled-temp"

  if (!$RunningOnLinux) {
    New-Item -ItemType Directory -Force $ControlledTemp | Out-Null
  }

  foreach ($Name in @("TEMP", "TMP", "TMPDIR")) {
    $EnvironmentSnapshot[$Name] = [Environment]::GetEnvironmentVariable(
      $Name,
      [EnvironmentVariableTarget]::Process
    )

    $InjectedTempValue = if ($RunningOnLinux) {
      $null
    }
    else {
      $ControlledTemp
    }

    [Environment]::SetEnvironmentVariable(
      $Name,
      $InjectedTempValue,
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
    foreach ($Name in @("TEMP", "TMP", "TMPDIR")) {
      [Environment]::SetEnvironmentVariable(
        $Name,
        $EnvironmentSnapshot[$Name],
        [EnvironmentVariableTarget]::Process
      )
    }
  }

  if ($HandshakeResult.Code -ne 0) {
    throw "Default handshake failed without TEMP/TMP/TMPDIR.`n$($HandshakeResult.Text)"
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

  if (!$RunningOnLinux) {
    $ExpectedTempDirectory = [System.IO.Path]::GetFullPath($ControlledTemp)
    $ActualTempDirectory = [System.IO.Path]::GetDirectoryName(
      [System.IO.Path]::GetFullPath($GeneratedHandshakePath)
    )

    if (![System.StringComparer]::OrdinalIgnoreCase.Equals(
      $ExpectedTempDirectory,
      $ActualTempDirectory
    )) {
      throw "Default handshake was not written to the controlled Windows temp directory. Expected=$ExpectedTempDirectory Actual=$ActualTempDirectory"
    }
  }

  $Handshake = (
    [System.IO.File]::ReadAllText(
      $GeneratedHandshakePath,
      [System.Text.Encoding]::UTF8
    ) |
      ConvertFrom-Json
  )

  if ($Handshake.schema_version -ne "1.1.0" -or
      $Handshake.runtime_version -ne "1.2.1" -or
      $Handshake.routing_valid -ne $true) {
    throw "Default handshake content is invalid."
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

    if ($Manifest.package_version -ne "1.2.4" -or
        $Manifest.runtime_version -ne "1.2.1" -or
        $Manifest.mode -ne "adopt") {
      throw "Clean linked-worktree adoption manifest is invalid."
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
