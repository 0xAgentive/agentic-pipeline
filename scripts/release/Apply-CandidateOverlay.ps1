[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CandidateRoot,
  [Parameter(Mandatory = $true)][string]$PayloadRoot,
  [string[]]$ExpectedPaths = @(),
  [switch]$Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Candidate = (Resolve-Path -LiteralPath $CandidateRoot).Path
$Payload = (Resolve-Path -LiteralPath $PayloadRoot).Path
. (Join-Path $PSScriptRoot '..\windows\common\NativeProcess.ps1')

function Resolve-Confined([string]$Root, [string]$Relative) {
  $Value = $Relative.Replace('\', '/').Trim()
  while ($Value.StartsWith('./', [StringComparison]::Ordinal)) { $Value = $Value.Substring(2) }
  if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value) -or $Value.Contains(':') -or $Value -match '(^|/)\.\.(/|$)') { throw "Unsafe overlay path: $Relative" }
  $RootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  $Full = [IO.Path]::GetFullPath((Join-Path $RootFull $Value.Replace('/', '\')))
  if (-not $Full.StartsWith($RootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Overlay path escapes root: $Relative" }
  return $Full
}

function Invoke-Git([string[]]$Arguments) {
  $Result = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList (@('-C', $Candidate) + $Arguments)
  Assert-AgenticNativeSuccess -Result $Result -Description 'git overlay operation'
  return $Result
}

$Inside = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if ($Inside.StdOut.Trim() -ne 'true') { throw 'CandidateRoot is not a Git worktree.' }
$Plan = New-Object System.Collections.Generic.List[object]
if ($ExpectedPaths.Count -eq 0) {
  [ordered]@{ status = 'PASS'; applied = $false; expected_paths = @(); skipped_reason = 'no_expected_changes' } | ConvertTo-Json -Depth 5
  return
}

foreach ($RawPath in @($ExpectedPaths | Sort-Object -Unique)) {
  $Relative = $RawPath.Replace('\', '/').Trim()
  while ($Relative.StartsWith('./', [StringComparison]::Ordinal)) { $Relative = $Relative.Substring(2) }
  $PayloadPath = Resolve-Confined -Root $Payload -Relative $Relative
  $CandidatePath = Resolve-Confined -Root $Candidate -Relative $Relative
  if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) { throw "Expected payload file missing: $Relative" }
  $PayloadBlob = (Invoke-Git @('hash-object', '--no-filters', '--', $PayloadPath)).StdOut.Trim()
  $HeadResult = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C', $Candidate, 'rev-parse', "HEAD:$Relative")
  $HeadBlob = if ($HeadResult.ExitCode -eq 0) { $HeadResult.StdOut.Trim() } else { $null }
  $Action = if ($HeadBlob -eq $PayloadBlob) { 'skip_blob_identical' } else { 'materialize_expected_change' }
  [void]$Plan.Add([pscustomobject]@{ path = $Relative; action = $Action; head_blob = $HeadBlob; payload_blob = $PayloadBlob })
  if (-not $Apply -or $Action -eq 'skip_blob_identical') { continue }

  $TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-overlay-' + [Guid]::NewGuid().ToString('N'))
  $IndexPath = Join-Path $TempRoot 'index'
  $StageRoot = Join-Path $TempRoot 'stage'
  New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null
  $PreviousIndex = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', 'Process')
  try {
    [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $IndexPath, 'Process')
    Invoke-Git @('read-tree', 'HEAD') | Out-Null
    $StoredBlob = (Invoke-Git @('hash-object', '-w', '--no-filters', '--', $PayloadPath)).StdOut.Trim()
    $ModeResult = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C', $Candidate, 'ls-files', '-s', '--', $Relative)
    $Mode = if ($ModeResult.ExitCode -eq 0 -and $ModeResult.StdOut -match '^(\d{6})\s') { $Matches[1] } else { '100644' }
    Invoke-Git @('update-index', '--add', '--cacheinfo', "$Mode,$StoredBlob,$Relative") | Out-Null
    $Prefix = $StageRoot.TrimEnd('\') + '\'
    Invoke-Git @('checkout-index', '--force', "--prefix=$Prefix", '--', $Relative) | Out-Null
    $Materialized = Join-Path $StageRoot $Relative.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $Materialized -PathType Leaf)) { throw "Attribute-aware materialization failed: $Relative" }
    $Parent = Split-Path -Parent $CandidatePath
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $TempTarget = Join-Path $Parent ('.overlay-' + [Guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllBytes($TempTarget, [IO.File]::ReadAllBytes($Materialized)); Move-Item -LiteralPath $TempTarget -Destination $CandidatePath -Force }
    finally { Remove-Item -LiteralPath $TempTarget -Force -ErrorAction SilentlyContinue }
  }
  finally {
    [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $PreviousIndex, 'Process')
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

[ordered]@{ status = 'PASS'; applied = [bool]$Apply; expected_paths = @($ExpectedPaths); plan = $Plan.ToArray() } | ConvertTo-Json -Depth 10
