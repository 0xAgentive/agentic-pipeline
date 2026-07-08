$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root
$changed = @()
try { $changed += git diff --name-only --; $changed += git diff --name-only --cached -- } catch { Write-Error "git diff failed; fastpatch denied"; exit 1 }
$changed = $changed | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique
if ($changed.Count -eq 0) { Write-Host "No changed files. Fastpatch gate passes trivially."; exit 0 }
$allowed = @('^src/frontend/components/', '^src/frontend/styles/', '^src/frontend/.*\.css$')
$blocked=@()
foreach ($file in $changed) { $norm=$file -replace '\\','/'; $ok=$false; foreach($rx in $allowed){ if($norm -match $rx){$ok=$true;break} }; if(-not $ok){$blocked+=$file} }
if($blocked.Count -gt 0){ Write-Host "FASTPATCH DENIED."; $blocked | ForEach-Object { Write-Host "- $_" }; exit 1 }
Write-Host "FASTPATCH ALLOWED."; exit 0
