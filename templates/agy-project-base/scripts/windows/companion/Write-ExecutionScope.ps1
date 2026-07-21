[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [Parameter(Mandatory=$true)][string]$WorkItemId,
  [Parameter(Mandatory=$true)][string[]]$AllowedPath,
  [string[]]$ForbiddenDomain = @(),
  [ValidateSet('exact','blocked')][string]$Status = 'exact',
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
$OutputPath = Join-Path $Project '.agy\EXECUTION_SCOPE.json'
$SchemaPath = Join-Path $Pipeline 'schemas\companion\execution-scope.schema.json'
$Validator = Join-Path $Pipeline 'scripts\companion\companion-control.cjs'
$Head = (@(& git -C $Project rev-parse HEAD 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve project HEAD.' }
$NormalizedPaths = New-Object System.Collections.Generic.List[string]
foreach ($PathValue in @($AllowedPath)) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) { continue }
  $Value = $PathValue.Replace('\','/').TrimStart([char[]]@('.','/'))
  if ($Value -match '(^|/)\.\.(/|$)' -or $Value -match '\*\*') {
    throw "Execution scope contains a broad or traversal path: $PathValue"
  }
  if (!$NormalizedPaths.Contains($Value)) { [void]$NormalizedPaths.Add($Value) }
}
if ($Status -eq 'exact' -and $NormalizedPaths.Count -eq 0) { throw 'Exact execution scope requires at least one path.' }
$Document = [ordered]@{
  schema_version = '1.0.0'
  work_item_id = $WorkItemId
  status = $Status
  project_root = $Project
  git_head = $Head
  allowed_paths = [string[]]$NormalizedPaths.ToArray()
  forbidden_domains = [string[]]@($ForbiddenDomain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  external_drift = $false
  generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  notes = @()
}
$Temp = $OutputPath + '.tmp'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
[System.IO.File]::WriteAllText($Temp, ($Document | ConvertTo-Json -Depth 20), $Utf8NoBom)
try {
  & node $Validator validate-execution-scope --repo-root $Pipeline --file $Temp
  if ($LASTEXITCODE -ne 0) { throw 'Execution scope failed schema validation.' }
  Publish-AtomicFile -SourcePath $Temp -TargetPath $OutputPath
}
finally {
  Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}
Write-Host "Execution scope written: $OutputPath"
