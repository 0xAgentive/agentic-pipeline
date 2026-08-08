[CmdletBinding()]
param(
  [string]$RepoRoot = ".",
  [string]$Version = "",
  [string]$OutputRoot = "",
  [switch]$Force,
  [switch]$SkipPreValidation
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$HostExe = (Get-Process -Id $PID).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'common\NativeProcess.ps1')

function Write-Utf8NoBom([string]$Path,[string]$Text) {
  $Parent = Split-Path -Parent $Path
  if ($Parent) { New-Item -ItemType Directory -Force $Parent | Out-Null }
  [System.IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$ArgumentList = @()
  )

  $Result = Invoke-AgenticNativeProcess -FilePath $FilePath -ArgumentList $ArgumentList
  return [pscustomobject]@{
    Code = [int]$Result.ExitCode
    Lines = @($Result.StdOutLines)
    ErrorLines = @($Result.StdErrLines)
    Text = [string]$Result.StdOut
    ErrorText = [string]$Result.StdErr
  }
}

function Invoke-Native {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$LogPath = ""
  )

  $Result = Invoke-NativeCapture -FilePath $FilePath -ArgumentList $ArgumentList
  foreach ($Line in $Result.Lines) { Write-Host $Line }
  foreach ($Line in $Result.ErrorLines) { Write-Host $Line }
  if ($LogPath) {
    Add-Content -LiteralPath $LogPath -Value $Result.Text -Encoding UTF8
    if ($Result.ErrorText) { Add-Content -LiteralPath $LogPath -Value $Result.ErrorText -Encoding UTF8 }
  }
  if ($Result.Code -ne 0) {
    throw "Command failed with exit code $($Result.Code): $FilePath ($($Result.ErrorText.Trim()))"
  }
}


function Invoke-AdvisoryValidator {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$ArgumentList = @(),
    [Parameter(Mandatory=$true)][string]$LogPath
  )

  Add-Content -LiteralPath $LogPath -Value ("`n=== " + $Name + " (advisory) ===") -Encoding UTF8
  $Result = Invoke-NativeCapture -FilePath $HostExe -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) + $ArgumentList)
  foreach ($Line in $Result.Lines) { Write-Host $Line }
  foreach ($Line in $Result.ErrorLines) { Write-Host $Line }
  Add-Content -LiteralPath $LogPath -Value $Result.Text -Encoding UTF8
  if ($Result.ErrorText) { Add-Content -LiteralPath $LogPath -Value $Result.ErrorText -Encoding UTF8 }
  if ($Result.Code -ne 0) {
    Write-Warning "$Name reported advisory issues. Release packaging continues because core operational gates are separate."
  }
}
function Invoke-Validator {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$ArgumentList = @(),
    [Parameter(Mandatory=$true)][string]$LogPath
  )

  Add-Content -LiteralPath $LogPath -Value ("`n=== " + $Name + " ===") -Encoding UTF8
  Invoke-Native -FilePath $HostExe -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script) + $ArgumentList) -LogPath $LogPath
}

$WorkTreeResult = Invoke-NativeCapture `
  -FilePath 'git' `
  -ArgumentList @('-C',$Root,'rev-parse','--is-inside-work-tree')

if ($WorkTreeResult.Code -ne 0 -or $WorkTreeResult.Text.Trim() -ne 'true') {
  throw "Release packages must be built from a Git working tree: $Root"
}

$VersionFile = Join-Path $Root 'VERSION.json'
if (!(Test-Path -LiteralPath $VersionFile -PathType Leaf)) { throw "Missing VERSION.json" }
$VersionInfo = Get-Content -LiteralPath $VersionFile -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]$VersionInfo.package_version }
if ([string]::IsNullOrWhiteSpace($Version)) { throw "Release version is empty" }

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root ('.artifacts\releases\' + $Version)
}
$OutputFull = [System.IO.Path]::GetFullPath($OutputRoot)

$StatusResult = Invoke-NativeCapture -FilePath 'git' -ArgumentList @('-C',$Root,'status','--porcelain=v1','--untracked-files=all')
if ($StatusResult.Code -ne 0) { throw "git status failed: $($StatusResult.Text)" }
$Status = @($StatusResult.Lines)
if ($Status.Count -gt 0) {
  Write-Host "Working tree is not clean:"
  $Status | ForEach-Object { Write-Host $_ }
  throw "Refusing to build a release from a dirty working tree"
}

if (Test-Path -LiteralPath $OutputFull) {
  if (!$Force) { throw "Output already exists: $OutputFull. Use -Force to replace it." }
  Remove-Item -LiteralPath $OutputFull -Recurse -Force
}
New-Item -ItemType Directory -Force $OutputFull | Out-Null

$CommitResult = Invoke-NativeCapture -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD')
if ($CommitResult.Code -ne 0) { throw "Cannot resolve HEAD: $($CommitResult.Text)" }
$Commit = $CommitResult.Text.Trim()
$Prefix = "agentic-pipeline-$Version"
$ArchiveName = "$Prefix.zip"
$ArchivePath = Join-Path $OutputFull $ArchiveName
$LogPath = Join-Path $OutputFull 'validation.log'
Write-Utf8NoBom -Path $LogPath -Text ("Agentic Pipeline release validation`nVersion: $Version`nCommit: $Commit`nUTC: " + (Get-Date).ToUniversalTime().ToString('o') + "`n")

if (!$SkipPreValidation) {
  Invoke-AdvisoryValidator -Name 'Human Docs' -Script (Join-Path $Root 'scripts\windows\Test-HumanDocsCleanup.ps1') -ArgumentList @() -LogPath $LogPath
  Invoke-Validator -Name 'Hard Package' -Script (Join-Path $Root 'scripts\windows\Validate-AgenticPipelinePackage.ps1') -ArgumentList @('-RepoRoot',$Root,'-Strict') -LogPath $LogPath
  Invoke-Validator -Name 'Runtime Truth' -Script (Join-Path $Root 'scripts\windows\Test-RuntimeTruth.ps1') -ArgumentList @('-RepoRoot',$Root,'-StrictHotPath') -LogPath $LogPath
  Invoke-Validator -Name 'Distribution Integrity' -Script (Join-Path $Root 'scripts\windows\Test-DistributionIntegrity.ps1') -ArgumentList @('-RepoRoot',$Root) -LogPath $LogPath
  Invoke-AdvisoryValidator -Name 'Fastpatch Synthetic' -Script (Join-Path $Root 'scripts\windows\Test-FastPatchSynthetic.ps1') -ArgumentList @('-RepoRoot',$Root) -LogPath $LogPath
  Invoke-Validator -Name 'Autonomous Convergence' -Script (Join-Path $Root 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1') -ArgumentList @('-RepoRoot',$Root) -LogPath $LogPath
  $DiffCheck = Invoke-NativeCapture -FilePath 'git' -ArgumentList @('-C',$Root,'diff','--check')
  Add-Content -LiteralPath $LogPath -Value $DiffCheck.Text -Encoding UTF8
  if ($DiffCheck.Code -ne 0) { Write-Warning 'git diff --check reported whitespace-only issues; release packaging continues.' }
}

Add-Content -LiteralPath $LogPath -Value "`n=== git archive ===" -Encoding UTF8
Invoke-Native -FilePath 'git' -ArgumentList @('-C',$Root,'archive','--format=zip',("--prefix=$Prefix/"),'-o',$ArchivePath,'HEAD') -LogPath $LogPath

$ArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$ArchiveSize = (Get-Item -LiteralPath $ArchivePath).Length

$ExtractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agentic-release-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ExtractRoot | Out-Null

try {
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force
  $PackageRoot = Join-Path $ExtractRoot $Prefix
  if (!(Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "Archive prefix root is missing after extraction" }

  foreach ($Forbidden in @('.git','.pipeline_patch_backup','.artifacts')) {
    if (Test-Path -LiteralPath (Join-Path $PackageRoot $Forbidden)) { throw "Forbidden release path present: $Forbidden" }
  }

  Invoke-Validator -Name 'Extracted Hard Package' -Script (Join-Path $PackageRoot 'scripts\windows\Validate-AgenticPipelinePackage.ps1') -ArgumentList @('-RepoRoot',$PackageRoot,'-Strict') -LogPath $LogPath
  Invoke-Validator -Name 'Extracted Runtime Truth' -Script (Join-Path $PackageRoot 'scripts\windows\Test-RuntimeTruth.ps1') -ArgumentList @('-RepoRoot',$PackageRoot,'-StrictHotPath') -LogPath $LogPath
  Invoke-Validator -Name 'Extracted Distribution Integrity' -Script (Join-Path $PackageRoot 'scripts\windows\Test-DistributionIntegrity.ps1') -ArgumentList @('-RepoRoot',$PackageRoot,'-PackageMode') -LogPath $LogPath
  Invoke-Validator -Name 'Extracted Autonomous Convergence' -Script (Join-Path $PackageRoot 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1') -ArgumentList @('-RepoRoot',$PackageRoot) -LogPath $LogPath

  $Contents = @()
  foreach ($File in Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File | Sort-Object FullName) {
    $Rel = $File.FullName.Substring($PackageRoot.Length).TrimStart("\","/") -replace '\\','/'
    $Contents += [ordered]@{
      path = $Rel
      size_bytes = $File.Length
      sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }

  $ContentsPath = Join-Path $OutputFull 'PACKAGE_CONTENTS.json'
  Write-Utf8NoBom -Path $ContentsPath -Text ($Contents | ConvertTo-Json -Depth 6)
}
finally {
  Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$Manifest = [ordered]@{
  schema_version = '1.0.0'
  artifact_type = 'agentic-pipeline-release'
  package_version = $Version
  playbook_version = $VersionInfo.playbook_version
  companion_version = $VersionInfo.companion_version
  source = [ordered]@{ type = 'git-tree'; commit = $Commit; tracked_only = $true }
  created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  archive = [ordered]@{ file = $ArchiveName; size_bytes = $ArchiveSize; sha256 = $ArchiveHash }
  validation = [ordered]@{ status = 'pass'; log = 'validation.log'; extracted_package_validated = $true }
  excluded_by_construction = @('.git','.pipeline_patch_backup','.artifacts','untracked files','ignored files')
}

Write-Utf8NoBom -Path (Join-Path $OutputFull 'ARTIFACT_MANIFEST.json') -Text ($Manifest | ConvertTo-Json -Depth 8)
Write-Utf8NoBom -Path (Join-Path $OutputFull 'SHA256SUMS') -Text ("$ArchiveHash  $ArchiveName`n")

Write-Host "Release package built and validated: $ArchivePath"
Write-Host "SHA-256: $ArchiveHash"
exit 0
