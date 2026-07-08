param(
  [string]$Event = "manual"
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

New-Item -ItemType Directory -Force ".agy\checkpoints" | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$base = ".agy\checkpoints\$stamp"

try {
  git status --short | Set-Content "$base.status.txt" -Encoding UTF8
  git diff --stat | Set-Content "$base.diffstat.txt" -Encoding UTF8
  git diff --binary | Set-Content "$base.patch" -Encoding UTF8
} catch {
  "git checkpoint capture failed: $($_.Exception.Message)" | Set-Content "$base.error.txt" -Encoding UTF8
}

@{
  event = $Event
  checkpoint = $base
  utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} | ConvertTo-Json -Compress
