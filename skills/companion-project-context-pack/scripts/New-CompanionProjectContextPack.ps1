[CmdletBinding()]
param(
  [string]$ProjectRoot = '.',
  [string]$OutputDirectory = "$env:USERPROFILE\Documents\antigravity\companion-packs",
  [string]$EcosystemVersion = '1.2.27',
  [ValidateRange(0, 100)][int]$MaxPackageMB = 0,
  [ValidateRange(1, 100000000)][long]$MaxTotalBytes = 100000000,
  [string]$PolicyPath,
  [string]$CapturedAt,
  [string]$PythonExecutable,
  [switch]$NoClipboard,
  [switch]$NoAliases,
  [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Force is retained for existing invocation compatibility; it never bypasses safety.
# MaxPackageMB is an optional decimal-MB ceiling. The old unused 35-MB default
# no longer silently constrains source ingestion; both totals are capped at 100 MB.
if ($MaxPackageMB -gt 0) {
  $MaxTotalBytes = [Math]::Min($MaxTotalBytes, [long]$MaxPackageMB * 1000000)
}
$TargetRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$HelperPath = Join-Path $PSScriptRoot 'companion_pack.py'
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
  throw 'Missing companion_pack.py beside the PowerShell entry point.'
}

$PythonPrefix = @()
if (-not $PythonExecutable) {
  foreach ($Candidate in @('python', 'python3', 'py')) {
    $Command = Get-Command $Candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Command) {
      $PythonExecutable = $Command.Source
      if ($Candidate -eq 'py') { $PythonPrefix = @('-3') }
      break
    }
  }
}
if (-not $PythonExecutable) {
  throw 'Python 3.10+ is required for the validated pack builder. No source export was published.'
}
$VersionCheck = & $PythonExecutable @PythonPrefix -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 2)'
if ($LASTEXITCODE -ne 0) { throw 'Selected Python must be version 3.10 or later.' }

# Arguments are passed as an array; repository names are never evaluated as code.
$HelperArgs = @('-X', 'utf8', $HelperPath, '--project-root', $TargetRoot,
  '--output-directory', $OutputDirectory, '--ecosystem-version', $EcosystemVersion,
  '--max-bytes', [string]$MaxTotalBytes)
if ($PolicyPath) {
  $HelperArgs += @('--policy', (Resolve-Path -LiteralPath $PolicyPath).Path)
}
if ($CapturedAt) { $HelperArgs += @('--captured-at', $CapturedAt) }
if (-not $NoAliases) { $HelperArgs += '--publish-aliases' }
$ResultText = & $PythonExecutable @PythonPrefix @HelperArgs
if ($LASTEXITCODE -ne 0) { throw 'Validated companion export failed. Existing archives and good aliases were preserved unless alias publication itself was interrupted; recover from the immutable archive.' }
$Result = ($ResultText -join "`n") | ConvertFrom-Json
if ($Result.Status -ne 'validated_source_snapshot') { throw 'Unexpected exporter result status.' }

Write-Host ("Companion snapshot: {0}" -f $Result.ArchivePath) -ForegroundColor Green
Write-Host ("ZIP bytes: {0}; expanded bytes: {1}; SHA-256: {2}" -f $Result.SizeBytes, $Result.ExpandedBytes, $Result.Sha256)
if (-not $NoClipboard) {
  try { Set-Clipboard -Value $Result.ArchivePath } catch { Write-Warning 'Could not copy the archive path to clipboard.' }
}
return $Result
