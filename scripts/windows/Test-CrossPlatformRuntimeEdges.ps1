[CmdletBinding()]
param(
  [string]$RepoRoot = "."
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$PathComparison = if (
  [System.Environment]::OSVersion.Platform -eq
  [System.PlatformID]::Win32NT
) {
  [System.StringComparison]::OrdinalIgnoreCase
}
else {
  [System.StringComparison]::Ordinal
}
$PathSeparators = [char[]]@(
  [System.IO.Path]::DirectorySeparatorChar,
  [System.IO.Path]::AltDirectorySeparatorChar
)
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

function Read-RepoText {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  return [System.IO.File]::ReadAllText((Join-Path $Root $RelativePath), [System.Text.Encoding]::UTF8)
}

$OverlayText = Read-RepoText 'scripts/release/Apply-CandidateOverlay.ps1'
$RuntimeUpdaterText = Read-RepoText 'scripts/windows/Update-AgenticProjectRuntime-v1.2.15.ps1'
$BridgeE2EText = Read-RepoText 'tests/acceptance/Test-ActionBridgeEndToEnd.ps1'
$BridgeInstallerText = Read-RepoText 'tests/acceptance/Test-ActionBridgeInstallerTransaction.ps1'
$BridgeInstallerSourceText = Read-RepoText 'scripts/bridge/Install-CompanionActionBridge.ps1'
$ContextBindingText = Read-RepoText 'tests/acceptance/Test-ContextHandoffAssetBinding.ps1'
$HookContractText = Read-RepoText 'templates/agy-project-base/.agents/hooks/Test-HookContract.ps1'
$WorkflowText = Read-RepoText '.github/workflows/validate.yml'
$BackslashOnlyTempPrefix = @'
.TrimEnd('\') + '\'
'@.Trim()
$BackslashOnlyRootPrefix = @'
$RootFull + '\'
'@.Trim()
if (-not $OverlayText.Contains('[IO.Path]::DirectorySeparatorChar') -or $OverlayText.Contains($BackslashOnlyRootPrefix)) {
  throw 'Candidate overlay confinement is not platform-separator aware.'
}
if (-not $RuntimeUpdaterText.Contains('[IO.Path]::DirectorySeparatorChar') -or $RuntimeUpdaterText.Contains($BackslashOnlyRootPrefix)) {
  throw 'Runtime updater confinement is not platform-separator aware.'
}
foreach ($Contract in @($BridgeE2EText, $BridgeInstallerText, $ContextBindingText)) {
  if ($Contract.Contains($BackslashOnlyTempPrefix)) { throw 'Acceptance cleanup guard still hardcodes a Windows-only temporary-path prefix.' }
}
if (-not $BridgeInstallerSourceText.Contains('[IO.Path]::DirectorySeparatorChar') -or $BridgeInstallerSourceText.Contains($BackslashOnlyTempPrefix) -or $BridgeInstallerSourceText.Contains($BackslashOnlyRootPrefix)) {
  throw 'Action Bridge installer path confinement is not platform-separator aware.'
}
if ($HookContractText.Contains("Join-Path `$PSScriptRoot '..\..'") -or -not $HookContractText.Contains('Split-Path -Parent') -or $HookContractText.Contains('Join-Path $env:TEMP')) {
  throw 'Hook contract still resolves its default project root with a Windows-only relative path.'
}
foreach ($RequiredCleanupGuard in @(
  '[IO.Path]::GetFullPath([IO.Path]::GetTempPath())',
  'function Test-UnsafeTemporaryBase',
  'Test-UnsafeTemporaryBase -Path $TempVolumeRoot',
  'Test-UnsafeTemporaryBase -Path $ResolvedTemp',
  '$ResolvedTemp.StartsWith($TempBasePrefix, $PathComparison)',
  '$ResolvedTemp.Equals($TempRoot, $PathComparison)'
)) {
  if (-not $HookContractText.Contains($RequiredCleanupGuard)) {
    throw "Hook contract cleanup is missing a required temporary-path confinement guard: $RequiredCleanupGuard"
  }
}
if ($ContextBindingText -notmatch 'RunningOnWindows' -or $WorkflowText -notmatch '(?s)validate-windows-unicode:.*?Full Windows distribution integrity.*?Test-DistributionIntegrity\.ps1') {
  throw 'Windows-only Context Handoff execution is not paired with full windows-latest distribution coverage.'
}
Write-Host 'CI path-portability regression contract passed.'

function Test-UnsafeTemporaryBase {
  param([Parameter(Mandatory = $true)][string]$Path)
  $Full = [System.IO.Path]::GetFullPath($Path)
  $Normalized = $Full.TrimEnd($PathSeparators)
  $VolumeRoot = [System.IO.Path]::GetPathRoot($Full)
  if ([string]::IsNullOrWhiteSpace($Normalized) -or
      [string]::IsNullOrWhiteSpace($VolumeRoot)) {
    return $true
  }
  $NormalizedVolumeRoot = [System.IO.Path]::GetFullPath($VolumeRoot).TrimEnd($PathSeparators)
  return $Normalized.Equals($NormalizedVolumeRoot, $PathComparison)
}

$TempBaseFull = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if (Test-UnsafeTemporaryBase -Path $TempBaseFull) {
  throw "Unsafe cross-platform temporary base: $TempBaseFull"
}
$TempBase = $TempBaseFull.TrimEnd($PathSeparators)
$TempVolumeRoot = [System.IO.Path]::GetPathRoot($TempBaseFull)
if (-not (Test-UnsafeTemporaryBase -Path $TempVolumeRoot)) {
  throw "Temporary volume-root rejection probe failed: $TempVolumeRoot"
}
$TempBasePrefix = $TempBase + [System.IO.Path]::DirectorySeparatorChar
$TempRootName = "agentic-cross-platform-edges-" + [Guid]::NewGuid().ToString("N")
$TempRoot = [System.IO.Path]::GetFullPath((Join-Path $TempBase $TempRootName)).TrimEnd($PathSeparators)
if (-not $TempRoot.StartsWith($TempBasePrefix, $PathComparison) -or
    $TempRoot.Equals($TempBase, $PathComparison) -or
    (Test-UnsafeTemporaryBase -Path $TempRoot) -or
    (Split-Path -Leaf $TempRoot) -cnotmatch '^agentic-cross-platform-edges-[0-9a-f]{32}$') {
  throw "Unsafe cross-platform temporary root: $TempRoot"
}

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

function Get-ExpectedDefaultHandshakeRoot {
  $Candidates = New-Object System.Collections.Generic.List[string]
  $IsWindowsPlatform = (
    [System.Environment]::OSVersion.Platform -eq
    [System.PlatformID]::Win32NT
  )
  $UserProfile = [System.Environment]::GetFolderPath(
    [System.Environment+SpecialFolder]::UserProfile
  )

  if ($IsWindowsPlatform) {
    $LocalApplicationData = [System.Environment]::GetFolderPath(
      [System.Environment+SpecialFolder]::LocalApplicationData
    )
    if (-not [string]::IsNullOrWhiteSpace($LocalApplicationData)) {
      [void]$Candidates.Add([System.IO.Path]::Combine($LocalApplicationData, 'Temp'))
    }
    if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
      [void]$Candidates.Add([System.IO.Path]::Combine($UserProfile, 'AppData', 'Local', 'Temp'))
    }
  }
  else {
    foreach ($Value in @($env:XDG_RUNTIME_DIR, $env:XDG_CACHE_HOME)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$Value)) {
        [void]$Candidates.Add([string]$Value)
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
      [void]$Candidates.Add([System.IO.Path]::Combine($UserProfile, '.cache'))
    }
    [void]$Candidates.Add('/tmp')
  }
  try { [void]$Candidates.Add([System.IO.Path]::GetTempPath()) }
  catch { }

  foreach ($Candidate in @($Candidates | Select-Object -Unique)) {
    $ProbePath = $null
    try {
      $ExpandedCandidate = [System.Environment]::ExpandEnvironmentVariables([string]$Candidate)
      if (-not [System.IO.Path]::IsPathRooted($ExpandedCandidate)) { continue }
      $BaseRoot = [System.IO.Path]::GetFullPath($ExpandedCandidate)
      $ExpectedRoot = [System.IO.Path]::Combine($BaseRoot, 'agentic-pipeline', 'runtime-handshake')
      [System.IO.Directory]::CreateDirectory($ExpectedRoot) | Out-Null
      $ProbePath = [System.IO.Path]::Combine($ExpectedRoot, '.expected-root-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
      [System.IO.File]::WriteAllText($ProbePath, '', $Utf8NoBom)
      [System.IO.File]::Delete($ProbePath)
      return [System.IO.Path]::GetFullPath($ExpectedRoot).TrimEnd($PathSeparators)
    }
    catch {
      if ($ProbePath) { Remove-Item -LiteralPath $ProbePath -Force -ErrorAction SilentlyContinue }
    }
  }

  throw 'Unable to determine the exact default runtime-handshake directory.'
}

function Remove-BoundHandshakeFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedRoot
  )
  $Full = [System.IO.Path]::GetFullPath($Path)
  $Parent = [System.IO.Path]::GetDirectoryName($Full)
  $Leaf = [System.IO.Path]::GetFileName($Full)
  if (-not $Parent.Equals($ExpectedRoot, $PathComparison) -or
      $Leaf -cnotmatch '^runtime-handshake-[0-9]{8}-[0-9]{6}-[0-9a-f]{32}\.json$') {
    throw "Refusing to delete an unbound runtime-handshake path: $Full"
  }
  if (Test-Path -LiteralPath $Full -PathType Leaf) {
    Remove-Item -LiteralPath $Full -Force
  }
}

$ExpectedHandshakeRoot = $null
$GeneratedHandshakeFullPath = $null
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
    $ExpectedHandshakeRoot = Get-ExpectedDefaultHandshakeRoot
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

  $ProjectFullPath = [System.IO.Path]::GetFullPath($Project).TrimEnd(
    $PathSeparators
  )
  $ProjectPrefix = $ProjectFullPath + [System.IO.Path]::DirectorySeparatorChar

  if ($GeneratedHandshakeFullPath.StartsWith($ProjectPrefix, $PathComparison)) {
    throw "Default handshake output was written inside the project: $GeneratedHandshakeFullPath"
  }

  $GeneratedHandshakeParentFull = [System.IO.Path]::GetFullPath(
    $GeneratedHandshakeParent
  ).TrimEnd($PathSeparators)
  $GeneratedHandshakeLeaf = [System.IO.Path]::GetFileName($GeneratedHandshakeFullPath)
  if (-not $GeneratedHandshakeParentFull.Equals($ExpectedHandshakeRoot, $PathComparison) -or
      $GeneratedHandshakeLeaf -cnotmatch '^runtime-handshake-[0-9]{8}-[0-9]{6}-[0-9a-f]{32}\.json$') {
    throw (
      "Default handshake output is not bound to the exact expected temporary directory and leaf pattern: " +
      "$GeneratedHandshakeFullPath expected_parent=$ExpectedHandshakeRoot"
    )
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

  Remove-BoundHandshakeFile -Path $GeneratedHandshakeFullPath -ExpectedRoot $ExpectedHandshakeRoot
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
      Join-Path (Join-Path $LinkedTarget '.agy') 'INSTALLATION_MANIFEST.json'
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

    $ManifestPath = Join-Path (Join-Path $LinkedTarget '.agy') 'INSTALLATION_MANIFEST.json'
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
  if (-not [string]::IsNullOrWhiteSpace($GeneratedHandshakeFullPath) -and
      -not [string]::IsNullOrWhiteSpace($ExpectedHandshakeRoot)) {
    Remove-BoundHandshakeFile -Path $GeneratedHandshakeFullPath -ExpectedRoot $ExpectedHandshakeRoot
  }
  if (Test-Path -LiteralPath $TempRoot -PathType Container) {
    $ResolvedTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TempRoot).Path).TrimEnd($PathSeparators)
    if (-not $ResolvedTemp.StartsWith($TempBasePrefix, $PathComparison) -or
        -not $ResolvedTemp.Equals($TempRoot, $PathComparison) -or
        $ResolvedTemp.Equals($TempBase, $PathComparison) -or
        (Test-UnsafeTemporaryBase -Path $ResolvedTemp) -or
        (Split-Path -Leaf $ResolvedTemp) -cnotmatch '^agentic-cross-platform-edges-[0-9a-f]{32}$') {
      throw "Unsafe cross-platform cleanup target: $ResolvedTemp"
    }
    Remove-Item -LiteralPath $ResolvedTemp -Recurse -Force
  }
}
