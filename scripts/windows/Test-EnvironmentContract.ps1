param([string]$ProjectRoot = (Get-Location).Path)
$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
Set-Location $ProjectRoot
$ok=$true
try { Get-Content ".agy\PHASE_STATUS.json" -Raw | ConvertFrom-Json | Out-Null; Write-Host "OK PHASE_STATUS" } catch { Write-Host "FAIL PHASE_STATUS"; $ok=$false }
$cfgPath="$env:USERPROFILE\.gemini\config\mcp_config.json"
try { $cfg=Get-Content $cfgPath -Raw | ConvertFrom-Json; Write-Host "OK MCP config" } catch { Write-Host "FAIL MCP config"; $ok=$false }
if (Test-Path "C:\Users\Public\mcp-wrappers\codebase-memory-mcp.cmd") { Write-Host "OK CBM wrapper" } else { Write-Host "FAIL CBM wrapper"; $ok=$false }
if ($ok) { exit 0 } else { exit 1 }
