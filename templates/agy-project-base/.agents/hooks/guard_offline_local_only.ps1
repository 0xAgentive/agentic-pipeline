param(
  [switch]$Strict
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$Findings = @()
$ScanRoots = @("src", "package.json")

foreach ($RootPath in $ScanRoots) {
  if (!(Test-Path $RootPath)) {
    continue
  }

  $Files = @()
  if (Test-Path $RootPath -PathType Leaf) {
    $Files = @(Get-Item $RootPath)
  } else {
    $Files = Get-ChildItem $RootPath -Recurse -File -ErrorAction SilentlyContinue
  }

  foreach ($File in $Files) {
    if ($File.FullName -match "\\node_modules\\|\\dist\\|\\build\\|\\.git\\") {
      continue
    }

    $Text = Get-Content $File.FullName -Raw -ErrorAction SilentlyContinue

    if ($Text -match "https?://|fetch\(|XMLHttpRequest|analytics|telemetry") {
      $Findings += $File.FullName
    }
  }
}

if ($Findings.Count -gt 0) {
  Write-Host "Potential external/network references:"
  $Findings | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }

  if ($Strict) {
    exit 1
  }
}

Write-Host "Offline/local-only guard completed."
exit 0