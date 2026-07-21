[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][ValidateSet('ready','active','implementation','repair','audit','completed','blocked','archived')][string]$Status,
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

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Project = (Resolve-Path -LiteralPath $ProjectRoot).Path
$Pipeline = (Resolve-Path -LiteralPath $PipelineRoot).Path
$Path = Join-Path $Project '.agy\WORK_ITEM.json'
$Schema = Join-Path $Pipeline 'schemas\companion\work-item.schema.json'
$Validator = Join-Path $Pipeline 'scripts\companion\companion-control.cjs'
if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "WORK_ITEM.json not found: $Path" }
$Document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
$Document.status = $Status
$Document.updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
$Temp = $Path + '.tmp'
[System.IO.File]::WriteAllText($Temp, ($Document | ConvertTo-Json -Depth 20), $Utf8NoBom)
try {
  & node $Validator validate-work-item --repo-root $Pipeline --file $Temp
  if ($LASTEXITCODE -ne 0) { throw 'Updated work item failed schema validation.' }
  Publish-AtomicFile -SourcePath $Temp -TargetPath $Path
}
finally {
  Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}
Write-Host "Work item status: $Status"
