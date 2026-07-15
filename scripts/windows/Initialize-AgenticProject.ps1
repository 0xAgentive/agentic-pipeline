[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$TargetRoot,
  [ValidateSet("New","Adopt")][string]$Mode = "New",
  [ValidateSet("Fail","Keep","Replace")][string]$ConflictPolicy = "Fail",
  [string]$RepoRoot = "",
  [switch]$Apply,
  [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
}

$TemplateRoot = Join-Path $RepoRoot "templates\agy-project-base"
$ProfileName = if ($Mode -eq "New") { "new-project" } else { "adopt-existing" }
$ProfileRoot = Join-Path $RepoRoot ("templates\state-profiles\" + $ProfileName)
$ManifestWriter = Join-Path $RepoRoot "scripts\control-plane\write-installation-manifest.cjs"

if (!$PSBoundParameters.ContainsKey("ConflictPolicy") -and $Mode -eq "Adopt") {
  $ConflictPolicy = "Keep"
}

foreach ($Path in @($RepoRoot,$TemplateRoot,$ProfileRoot)) {
  if (!(Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Required directory not found: $Path"
  }
}
if (!(Test-Path -LiteralPath $ManifestWriter -PathType Leaf)) {
  throw "Shared installation manifest writer not found: $ManifestWriter"
}
if (!(Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js is required to write the installation manifest."
}

$TargetFull = [System.IO.Path]::GetFullPath($TargetRoot)
$ProjectName = Split-Path $TargetFull -Leaf

if ($Mode -eq "New" -and (Test-Path -LiteralPath $TargetFull)) {
  $Existing = @(Get-ChildItem -LiteralPath $TargetFull -Force -ErrorAction SilentlyContinue)
  if ($Existing.Count -gt 0 -and $ConflictPolicy -eq "Fail") {
    throw "New-project target is not empty: $TargetFull"
  }
}

if ($Mode -eq "Adopt" -and !(Test-Path -LiteralPath $TargetFull -PathType Container)) {
  throw "Adopt target does not exist: $TargetFull"
}

if ($Mode -eq "Adopt" -and
    (Test-Path -LiteralPath (Join-Path $TargetFull ".git")) -and
    !$AllowDirty) {
  $Status = @(& git -C $TargetFull status --porcelain=v1 --untracked-files=all 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "git status failed for adoption target"
  }
  if ($Status.Count -gt 0) {
    Write-Host "Adoption target is not clean:"
    $Status | ForEach-Object { Write-Host $_ }
    throw "Finish or stash active work before adoption, or explicitly use -AllowDirty after review."
  }
}

$BackupRoot = Join-Path $TargetFull (".pipeline_adopt_backup\" + $Stamp)
$Copied = New-Object System.Collections.Generic.List[string]
$Skipped = New-Object System.Collections.Generic.List[string]
$BackedUp = New-Object System.Collections.Generic.List[string]

function Write-Utf8NoBom {
  param([string]$Path,[string]$Text)
  $Parent = Split-Path -Parent $Path
  if ($Parent) {
    New-Item -ItemType Directory -Force $Parent | Out-Null
  }
  [System.IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Copy-One {
  param([string]$Source,[string]$Destination,[string]$RelativePath)

  if (Test-Path -LiteralPath $Destination -PathType Leaf) {
    if ($ConflictPolicy -eq "Fail") {
      throw "Conflict: $RelativePath"
    }
    if ($ConflictPolicy -eq "Keep") {
      [void]$Skipped.Add($RelativePath)
      return
    }

    $Backup = Join-Path $BackupRoot $RelativePath
    New-Item -ItemType Directory -Force (Split-Path -Parent $Backup) | Out-Null
    Copy-Item -LiteralPath $Destination -Destination $Backup -Force
    [void]$BackedUp.Add($RelativePath)
  }

  New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  [void]$Copied.Add($RelativePath)
}

$TemplateFiles = Get-ChildItem -LiteralPath $TemplateRoot -Recurse -Force -File |
  Sort-Object FullName

Write-Host "Mode: $Mode"
Write-Host "Target: $TargetFull"
Write-Host "Conflict policy: $ConflictPolicy"
Write-Host "Apply: $Apply"

if (!$Apply) {
  Write-Host "DRY RUN. No files changed."
  Write-Host "Template files considered: $($TemplateFiles.Count)"
  Write-Host "State profile: $ProfileName"
  return
}

New-Item -ItemType Directory -Force $TargetFull | Out-Null

foreach ($File in $TemplateFiles) {
  $Relative = $File.FullName.Substring($TemplateRoot.Length).TrimStart("\","/")

  if ($Relative -in @(
    ".agy\PHASE_STATUS.json",
    ".agy\AGENT_STATE.md",
    ".agy\RECOVERY_PROMPT.md"
  )) {
    continue
  }

  Copy-One `
    -Source $File.FullName `
    -Destination (Join-Path $TargetFull $Relative) `
    -RelativePath $Relative
}

$ExistingPhase = Join-Path $TargetFull ".agy\PHASE_STATUS.json"
$ShouldApplyProfile = (
  $Mode -eq "New" -or
  !(Test-Path -LiteralPath $ExistingPhase -PathType Leaf)
)

if ($ShouldApplyProfile) {
  foreach ($Name in @(
    "PHASE_STATUS.json",
    "AGENT_STATE.md",
    "RECOVERY_PROMPT.md"
  )) {
    $Source = Join-Path $ProfileRoot $Name
    $Destination = Join-Path $TargetFull (".agy\" + $Name)
    $Text = [System.IO.File]::ReadAllText(
      $Source,
      [System.Text.Encoding]::UTF8
    ).Replace("<ProjectName>",$ProjectName)

    Write-Utf8NoBom -Path $Destination -Text $Text
    [void]$Copied.Add(".agy\" + $Name)
  }
}
else {
  Write-Host "Existing .agy state preserved. The adoption profile was not forced over current state."
}

$Commit = "unknown"
if (Test-Path -LiteralPath (Join-Path $RepoRoot ".git")) {
  $CommitOutput = @(& git -C $RepoRoot rev-parse HEAD 2>&1)
  if ($LASTEXITCODE -eq 0) {
    $Commit = ($CommitOutput -join "`n").Trim()
  }
}

$ManifestMetadata = [ordered]@{
  installed_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  mode = $Mode.ToLowerInvariant()
  state_profile = $ProfileName
  source_repo = "agentic-pipeline"
  source_commit = $Commit
  conflict_policy = $ConflictPolicy
  copied = $Copied.ToArray()
  skipped = $Skipped.ToArray()
  backed_up = $BackedUp.ToArray()
  backup_root = if ($BackedUp.Count -gt 0) { $BackupRoot } else { $null }
  next_command = if ($Mode -eq "New") { "/specdoc" } else { "/landing" }
}

$MetadataPath = Join-Path $env:TEMP (
  "agentic-install-metadata-" + [Guid]::NewGuid().ToString("N") + ".json"
)
$ManifestPath = Join-Path $TargetFull ".agy\INSTALLATION_MANIFEST.json"

Write-Utf8NoBom `
  -Path $MetadataPath `
  -Text ($ManifestMetadata | ConvertTo-Json -Depth 20)

try {
  $WriterOutput = @(
    & node `
      $ManifestWriter `
      --repo-root $RepoRoot `
      --output $ManifestPath `
      --metadata-file $MetadataPath 2>&1
  )
  $WriterCode = $LASTEXITCODE

  if ($WriterCode -ne 0) {
    throw "Installation manifest writer failed with exit code $WriterCode.`n$($WriterOutput -join "`n")"
  }
}
finally {
  Remove-Item -LiteralPath $MetadataPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Installation complete."
Write-Host "Copied: $($Copied.Count); skipped: $($Skipped.Count); backed up: $($BackedUp.Count)"
Write-Host "Next command: $($ManifestMetadata.next_command)"
