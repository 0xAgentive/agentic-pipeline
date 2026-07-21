[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$InputFile,
  [string]$PipelineRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
function Publish-AtomicFile {
  param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$TargetPath
  )

  if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    throw 'Atomic publish source path is empty.'
  }
  if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    throw 'Atomic publish target path is empty.'
  }
  if (!(Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Atomic publish source file is missing: $SourcePath"
  }

  $TargetParent = Split-Path -Parent $TargetPath
  if ([string]::IsNullOrWhiteSpace($TargetParent)) {
    throw "Atomic publish target parent is empty: $TargetPath"
  }
  New-Item -ItemType Directory -Force -Path $TargetParent | Out-Null

  [System.IO.File]::Move($SourcePath, $TargetPath, $true)
}

$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$Source = (Resolve-Path -LiteralPath $InputFile).Path
$OutputPath = Join-Path $Project '.agy\RUN_RESULT.json'
$SchemaPath = Join-Path $Pipeline 'schemas\companion\run-result.schema.json'
$Validator = Join-Path $Pipeline 'scripts\companion\companion-control.cjs'
& node $Validator validate-run-result --repo-root $Pipeline --file $Source
if ($LASTEXITCODE -ne 0) { throw 'RUN_RESULT input failed schema validation.' }
$Temp = $OutputPath + '.tmp'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
Copy-Item -LiteralPath $Source -Destination $Temp -Force
try {
  Publish-AtomicFile -SourcePath $Temp -TargetPath $OutputPath
}
finally {
  Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}
Write-Host "Run result written: $OutputPath"
