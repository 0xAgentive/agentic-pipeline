param([string]$RepoRoot = ".")

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Errors = New-Object System.Collections.Generic.List[string]
function Add-Error([string]$Message) { [void]$Errors.Add($Message) }

$ScanRoots = @(
  "templates\agy-project-base",
  "runtime-src",
  "config"
)

$Terms = @(
  "Polar",
  "H10",
  "Athlete Cardio Lab",
  "Z:\Polar Logs",
  "AppSelect.tsx",
  "OverlayRoot.tsx"
)

foreach ($ScanRoot in $ScanRoots) {
  $Path = Join-Path $Root $ScanRoot
  if (!(Test-Path -LiteralPath $Path)) { continue }

  foreach ($File in Get-ChildItem -LiteralPath $Path -Recurse -Force -File) {
    if ($File.Extension.ToLowerInvariant() -notin @('.md','.json','.ps1','.cjs','.yml','.yaml','.txt')) { continue }
    $Text = [System.IO.File]::ReadAllText($File.FullName,[System.Text.Encoding]::UTF8)
    $Rel = $File.FullName.Substring($Root.Length).TrimStart("\","/") -replace '\\','/'

    foreach ($Term in $Terms) {
      if ($Text.IndexOf($Term,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Add-Error "Project-specific term '$Term' found in general runtime: $Rel"
      }
    }
  }
}

$ProductionScripts = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Recurse -File -Include '*.ps1','*.sh','*.cjs' |
  Where-Object { $_.Name -notmatch '^(Test|Validate)-' }

foreach ($File in $ProductionScripts) {
  $Text = [System.IO.File]::ReadAllText($File.FullName,[System.Text.Encoding]::UTF8)
  $Rel = $File.FullName.Substring($Root.Length).TrimStart("\","/") -replace '\\','/'
  foreach ($Term in $Terms) {
    if ($Text.IndexOf($Term,[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      Add-Error "Project-specific term '$Term' found in production script: $Rel"
    }
  }
}

if ($Errors.Count -gt 0) {
  Write-Host "Project-leakage validation failed:"
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Project-leakage validation passed."
exit 0
