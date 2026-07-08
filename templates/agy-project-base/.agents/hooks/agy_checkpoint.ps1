param(
  [string]$Event = "manual"
)

$ErrorActionPreference = "Stop"

if ([Console]::IsInputRedirected) {
  $null = [Console]::In.ReadToEnd()
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $Root

$CheckpointDir = Join-Path $Root ".agy\checkpoints"
New-Item -ItemType Directory -Force $CheckpointDir | Out-Null

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$StatusPath = Join-Path $CheckpointDir "git-status-$Stamp.txt"
$DiffStatPath = Join-Path $CheckpointDir "git-diff-stat-$Stamp.txt"

if (Get-Command git -ErrorAction SilentlyContinue) {
  git status --short 2>$null | Set-Content $StatusPath -Encoding UTF8
  git diff --stat 2>$null | Set-Content $DiffStatPath -Encoding UTF8
}

[Console]::Out.Write("{}")
exit 0