param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$CbmWrapperPath = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
Set-Location $ProjectRoot

if ([string]::IsNullOrWhiteSpace($CbmWrapperPath)) {
  $CbmWrapperPath = Join-Path $env:PUBLIC "mcp-wrappers\codebase-memory-mcp.cmd"
}

$ok = $true

if (Test-Path ".agy\PHASE_STATUS.json") {
  try {
    Get-Content ".agy\PHASE_STATUS.json" -Raw | ConvertFrom-Json | Out-Null
    Write-Host "OK PHASE_STATUS"
  } catch {
    Write-Host "FAIL PHASE_STATUS"
    $ok = $false
  }
} elseif (Test-Path "VERSION.json") {
  Write-Host "OK PHASE_STATUS (framework repository root)"
} else {
  Write-Host "FAIL PHASE_STATUS"
  $ok = $false
}

$cfgPath = Join-Path $env:USERPROFILE ".gemini\config\mcp_config.json"
try {
  Get-Content $cfgPath -Raw | ConvertFrom-Json | Out-Null
  Write-Host "OK MCP config"
} catch {
  Write-Host "FAIL MCP config"
  $ok = $false
}

if (Test-Path -LiteralPath $CbmWrapperPath -PathType Leaf) {
  Write-Host "OK CBM wrapper"
} else {
  Write-Host "FAIL CBM wrapper: $CbmWrapperPath"
  $ok = $false
}

if ($ok) { exit 0 }
exit 1
