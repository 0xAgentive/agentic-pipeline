[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# 1. Prune stale companion handoffs (keep 3 latest)
$HandoffPruner = "C:\Scripts\AntigravityProjects\companion-handoff\src\prune_stale_handoffs.py"
if (Test-Path $HandoffPruner) {
  python $HandoffPruner | Out-Null
}

# 2. Prune transport context (keep 5 latest)
$TransportPruner = "C:\Users\Администратор\Documents\antigravity\Agentic Pipeline\scripts\prune_transport_context.py"
if (Test-Path $TransportPruner) {
  python $TransportPruner | Out-Null
}

# 3. Clean stale TEMP files older than 24 hours
$Cutoff = (Get-Date).AddDays(-1)
Get-ChildItem -Path $env:TEMP -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $Cutoff } | ForEach-Object {
  try { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
}

# 4. Clean Antigravity shell cache if older than 24 hours
$AgCache = "C:\Users\Администратор\AppData\Roaming\Antigravity\Cache"
if (Test-Path $AgCache) {
  Get-ChildItem -Path $AgCache -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $Cutoff } | ForEach-Object {
    try { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# 5. Rotate action bridge logs > 5MB
$LogsDir = Join-Path $env:USERPROFILE ".agentic-pipeline\action-bridge\logs"
if (Test-Path $LogsDir) {
  Get-ChildItem -Path $LogsDir -Filter "*.log" -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 5MB } | ForEach-Object {
    try {
      $old = $_.FullName + ".old"
      if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
      Move-Item $_.FullName $old -Force -ErrorAction SilentlyContinue
    } catch {}
  }
}

# 6. Clean brain cache for conversations older than 14 days (protected active conversations are NEVER touched)
$BrainPruner = Join-Path $env:USERPROFILE "Documents\antigravity\Agentic Pipeline\scripts\clean_brain_cache.py"
if (Test-Path $BrainPruner) {
  python $BrainPruner | Out-Null
}

Write-Host "Antigravity Daily Maintenance Completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
