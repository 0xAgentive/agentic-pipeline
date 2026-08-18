[CmdletBinding()]
param(
  [string]$RepoRoot = '.',
  [string]$OutputRoot = '',
  [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

$VersionFile = Join-Path $Root 'VERSION.json'
if (-not (Test-Path -LiteralPath $VersionFile -PathType Leaf)) { throw "VERSION.json not found in $Root" }
$VersionInfo = Get-Content -LiteralPath $VersionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Version = [string]$VersionInfo.package_version

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $Root ".artifacts\audit\$Version"
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$ArchiveName = "agentic-pipeline-audit-v$Version.zip"
$ArchivePath = Join-Path $OutputRoot $ArchiveName
if ((Test-Path -LiteralPath $ArchivePath -PathType Leaf) -and -not $Force) {
  throw "Audit package already exists: $ArchivePath. Use -Force to overwrite."
}

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("agentic-audit-stage-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$IncludePatterns = @(
  'VERSION.json',
  'ECOSYSTEM_VERSION.json',
  'AGENTS.md',
  'README.md',
  '.agents/**',
  '.agy/**',
  'schemas/**',
  'scripts/**',
  'templates/**',
  'docs/**',
  'integrations/**',
  'tests/**',
  'evals/**',
  'config/**'
)

$ExcludePatterns = @(
  '*.git/**',
  '*.artifacts/**',
  '*node_modules/**',
  '*__pycache__/**',
  '*.pyc',
  '*.tmp',
  '*.log',
  '*coverage/**',
  '*.pytest_cache/**'
)

function Test-Included([string]$RelativePath) {
  $Norm = $RelativePath -replace '\\', '/'
  foreach ($Ex in $ExcludePatterns) {
    if ([Management.Automation.WildcardPattern]::new($Ex, [Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Norm)) {
      return $false
    }
  }
  foreach ($Inc in $IncludePatterns) {
    if ([Management.Automation.WildcardPattern]::new($Inc, [Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($Norm)) {
      return $true
    }
  }
  return $false
}

$StagedCount = 0
try {
  Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
    $Rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
    if (Test-Included $Rel) {
      $Dest = Join-Path $TempDir $Rel
      $Parent = Split-Path -Parent $Dest
      if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
      Copy-Item -LiteralPath $_.FullName -Destination $Dest -Force
      $StagedCount++
    }
  }

  if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
  Compress-Archive -Path (Join-Path $TempDir '*') -DestinationPath $ArchivePath -Force

  $Hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $Size = (Get-Item -LiteralPath $ArchivePath).Length

  $Manifest = [ordered]@{
    schema_version = '1.0.0'
    artifact_type = 'agentic-pipeline-audit-package'
    ecosystem_version = $Version
    package_version = $Version
    file_count = $StagedCount
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    archive = [ordered]@{
      file = $ArchiveName
      size_bytes = $Size
      sha256 = $Hash
    }
  }

  [IO.File]::WriteAllText((Join-Path $OutputRoot 'ARTIFACT_MANIFEST.json'), ($Manifest | ConvertTo-Json -Depth 8), $Utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $OutputRoot 'SHA256SUMS'), "$Hash  $ArchiveName`n", $Utf8NoBom)

  Write-Host "Audit package created: $ArchivePath" -ForegroundColor Green
  Write-Host "Files included: $StagedCount | Size: $Size bytes | SHA-256: $Hash" -ForegroundColor Cyan
}
finally {
  Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
