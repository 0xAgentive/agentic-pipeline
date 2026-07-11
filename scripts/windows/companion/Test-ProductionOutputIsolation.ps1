[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string[]]$ProductionPaths = @("outputs","data",".agy",".artifacts"),
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$CommandArguments = @(),
  [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$TempRoot = Join-Path $env:TEMP ("agy_output_isolation_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $TempRoot | Out-Null

function Get-Snapshot {
  param([string]$Root,[string[]]$RelativePaths)
  $Map = @{}
  foreach ($Relative in $RelativePaths) {
    $Base = Join-Path $Root $Relative
    if (!(Test-Path -LiteralPath $Base)) { continue }
    foreach ($File in Get-ChildItem -LiteralPath $Base -Recurse -Force -File -ErrorAction SilentlyContinue) {
      $Rel = $File.FullName.Substring($Root.Length).TrimStart("\","/") -replace '\\','/'
      $Map[$Rel] = [ordered]@{
        size_bytes = [int64]$File.Length
        sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    }
  }
  return $Map
}

function Compare-Snapshots {
  param($Before,$After)
  $Added = New-Object System.Collections.Generic.List[string]
  $Deleted = New-Object System.Collections.Generic.List[string]
  $Modified = New-Object System.Collections.Generic.List[string]
  foreach ($Key in $Before.Keys) {
    if (!$After.ContainsKey($Key)) { [void]$Deleted.Add($Key); continue }
    if ($Before[$Key].size_bytes -ne $After[$Key].size_bytes -or $Before[$Key].sha256 -ne $After[$Key].sha256) {
      [void]$Modified.Add($Key)
    }
  }
  foreach ($Key in $After.Keys) {
    if (!$Before.ContainsKey($Key)) { [void]$Added.Add($Key) }
  }
  return [ordered]@{
    added = [string[]]$Added.ToArray()
    deleted = [string[]]$Deleted.ToArray()
    modified = [string[]]$Modified.ToArray()
  }
}

$OldEnvironment = @{}
$Overrides = [ordered]@{
  AGY_TEST_ROOT = $TempRoot
  AGY_OUTPUT_ROOT = (Join-Path $TempRoot "outputs")
  AGY_DATA_ROOT = (Join-Path $TempRoot "data")
  AGY_ARTIFACT_ROOT = (Join-Path $TempRoot "artifacts")
  AGY_STATE_ROOT = (Join-Path $TempRoot "state")
}
foreach ($Name in $Overrides.Keys) {
  $OldEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
  [Environment]::SetEnvironmentVariable($Name, $Overrides[$Name], "Process")
  New-Item -ItemType Directory -Force $Overrides[$Name] | Out-Null
}

$Before = Get-Snapshot -Root $Project -RelativePaths $ProductionPaths
$StdoutPath = Join-Path $TempRoot "stdout.log"
$StderrPath = Join-Path $TempRoot "stderr.log"
$ExitCode = 999
try {
  Push-Location $Project
  try {
    $OldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Executable @CommandArguments 1> $StdoutPath 2> $StderrPath
    $ExitCode = $LASTEXITCODE
    $ErrorActionPreference = $OldPreference
  }
  finally {
    Pop-Location
  }
}
finally {
  foreach ($Name in $Overrides.Keys) {
    [Environment]::SetEnvironmentVariable($Name, $OldEnvironment[$Name], "Process")
  }
}

$After = Get-Snapshot -Root $Project -RelativePaths $ProductionPaths
$Diff = Compare-Snapshots -Before $Before -After $After
$ChangedCount = $Diff.added.Count + $Diff.deleted.Count + $Diff.modified.Count

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $ReportPath = Join-Path $TempRoot "production_output_isolation.json"
}
$Report = [ordered]@{
  schema_version = "1.0.0"
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  project_root = $Project
  command = $Executable
  arguments = [string[]]$CommandArguments
  exit_code = $ExitCode
  production_paths = [string[]]$ProductionPaths
  environment_overrides = $Overrides
  changes = $Diff
  production_changed = ($ChangedCount -gt 0)
  stdout_path = $StdoutPath
  stderr_path = $StderrPath
}
$Parent = Split-Path -Parent $ReportPath
if ($Parent) { New-Item -ItemType Directory -Force $Parent | Out-Null }
[System.IO.File]::WriteAllText($ReportPath, ($Report | ConvertTo-Json -Depth 20), $Utf8NoBom)

Write-Host "Command exit code: $ExitCode"
Write-Host "Production changes detected: $ChangedCount"
Write-Host "Report: $ReportPath"
if ($ChangedCount -gt 0) {
  foreach ($Item in $Diff.added) { Write-Host "ADDED: $Item" }
  foreach ($Item in $Diff.modified) { Write-Host "MODIFIED: $Item" }
  foreach ($Item in $Diff.deleted) { Write-Host "DELETED: $Item" }
  exit 1
}
if ($ExitCode -ne 0) { exit $ExitCode }
exit 0
