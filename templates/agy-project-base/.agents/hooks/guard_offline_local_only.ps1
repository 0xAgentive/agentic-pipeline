param(
  [switch]$Strict
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$scanRoots = @("src", "package.json", "package-lock.json") | Where-Object { Test-Path $_ }
if (!$scanRoots) {
  Write-Host "Offline/local-only guard skipped: no standard source roots found."
  exit 0
}

$pattern = '(https?://|telemetry|analytics|sentry|posthog|mixpanel|segment|google-analytics)'
$violations = @()

foreach ($root in $scanRoots) {
  if (Test-Path $root -PathType Leaf) {
    $files = @(Get-Item $root)
  } else {
    $files = Get-ChildItem $root -Recurse -File -Include *.ts,*.tsx,*.js,*.jsx,*.json,*.css,*.html -ErrorAction SilentlyContinue
  }

  foreach ($file in $files) {
    $text = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($text -match $pattern) {
      $rel = Resolve-Path $file.FullName -Relative
      $violations += $rel
    }
  }
}

$violations = $violations | Sort-Object -Unique

if ($violations.Count -gt 0) {
  Write-Host "Possible remote/telemetry/offline violations:"
  $violations | ForEach-Object { Write-Host " - $_" }
  if ($Strict) { exit 1 }
  exit 0
}

Write-Host "Offline/local-only guard OK."
exit 0
