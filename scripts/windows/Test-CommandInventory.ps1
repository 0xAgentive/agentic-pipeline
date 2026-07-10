param(
  [string]$RepoRoot = ".",
  [string]$ProjectRoot = "",
  [switch]$SkipDocumentationScan
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$TargetRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  Join-Path $Root "templates\agy-project-base"
} else {
  (Resolve-Path -LiteralPath $ProjectRoot).Path
}

$Errors = New-Object System.Collections.Generic.List[string]
function Add-Error([string]$Message) { [void]$Errors.Add($Message) }
function Read-Json([string]$Path) {
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
  catch { Add-Error "Invalid JSON: $Path :: $($_.Exception.Message)"; return $null }
}
function Hash([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$CanonicalPath = Join-Path $Root "config\command-inventory.json"
$TemplateInventoryPath = Join-Path $TargetRoot ".agents\COMMAND_INVENTORY.json"

foreach ($Path in @($CanonicalPath,$TemplateInventoryPath)) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Add-Error "Missing command inventory: $Path" }
}

if ((Hash $CanonicalPath) -ne (Hash $TemplateInventoryPath)) {
  Add-Error "Template command inventory differs from canonical config/command-inventory.json"
}

$Inventory = if (Test-Path -LiteralPath $CanonicalPath -PathType Leaf) { Read-Json $CanonicalPath } else { $null }
$VersionInfo = if (Test-Path -LiteralPath (Join-Path $Root "VERSION.json") -PathType Leaf) { Read-Json (Join-Path $Root "VERSION.json") } else { $null }
$Commands = @{}
$Workflows = @{}

if ($Inventory) {
  if ($Inventory.schema_version -ne "1.0.0") { Add-Error "Command inventory schema_version must be 1.0.0" }
  if ($VersionInfo -and $Inventory.runtime_version -ne $VersionInfo.runtime_version) { Add-Error "Command inventory runtime_version does not match VERSION.json" }

  foreach ($Entry in @($Inventory.commands)) {
    $Command = [string]$Entry.command
    $Workflow = [string]$Entry.workflow

    if ($Command -notmatch '^/[a-z][a-z0-9-]*$') { Add-Error "Invalid command name: $Command"; continue }
    if ($Commands.ContainsKey($Command)) { Add-Error "Duplicate command: $Command" } else { $Commands[$Command] = $Entry }
    if ($Workflows.ContainsKey($Workflow)) { Add-Error "Workflow assigned more than once: $Workflow" } else { $Workflows[$Workflow] = $Command }

    $WorkflowPath = Join-Path $TargetRoot ($Workflow -replace '/','\')
    if (!(Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) { Add-Error "$Command workflow missing: $Workflow" }

    foreach ($Required in @($Entry.required_paths)) {
      $RequiredPath = Join-Path $TargetRoot (($Required.ToString()) -replace '/','\')
      if (!(Test-Path -LiteralPath $RequiredPath)) { Add-Error "$Command required path missing: $Required" }
    }
  }
}

$WorkflowDir = Join-Path $TargetRoot ".agents\workflows"
if (Test-Path -LiteralPath $WorkflowDir -PathType Container) {
  foreach ($File in Get-ChildItem -LiteralPath $WorkflowDir -File -Filter "*.md") {
    $Rel = ".agents/workflows/" + $File.Name
    if (!$Workflows.ContainsKey($Rel)) { Add-Error "Orphan workflow not present in inventory: $Rel" }
  }
} else {
  Add-Error "Workflow directory missing: $WorkflowDir"
}

if (!$SkipDocumentationScan) {
  $DocPaths = @(
    "README.md","README.ru.md",
    "docs\reference\COMMANDS_CHEATSHEET.en.md","docs\reference\COMMANDS_CHEATSHEET.ru.md",
    "templates\agy-project-base\README_PIPELINE.en.md","templates\agy-project-base\README_PIPELINE.ru.md",
    "templates\agy-project-base\docs\COMMANDS_CHEATSHEET.en.md","templates\agy-project-base\docs\COMMANDS_CHEATSHEET.ru.md",
    "templates\agy-project-base\docs\START_HERE.en.md","templates\agy-project-base\docs\START_HERE.ru.md"
  )

  $Documented = New-Object System.Collections.Generic.HashSet[string]
  $BacktickPattern = '`(?<cmd>/[a-z][a-z0-9-]+)`'
  $LinePattern = '(?m)^\s{0,8}(?<cmd>/[a-z][a-z0-9-]+)(?:\s|$)'

  foreach ($RelPath in $DocPaths) {
    $Path = Join-Path $Root $RelPath
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Add-Error "Command documentation missing: $RelPath"; continue }
    $Text = Get-Content -LiteralPath $Path -Raw

    foreach ($Match in [regex]::Matches($Text,$BacktickPattern)) { [void]$Documented.Add($Match.Groups['cmd'].Value) }
    foreach ($Match in [regex]::Matches($Text,$LinePattern)) { [void]$Documented.Add($Match.Groups['cmd'].Value) }
  }

  foreach ($Command in $Documented) {
    if (!$Commands.ContainsKey($Command)) { Add-Error "Documented command missing from inventory: $Command" }
  }
}

if ($Errors.Count -gt 0) {
  Write-Host "Command-inventory validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Command-inventory validation passed. Commands: $($Commands.Count)"
exit 0
