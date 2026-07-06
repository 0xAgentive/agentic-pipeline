param([switch]$UpdateMcpConfig)
$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$WrapperDir = "C:\Users\Public\mcp-wrappers"
$CbmWrapper = Join-Path $WrapperDir "codebase-memory-mcp.cmd"
foreach ($dir in @($WrapperDir,"C:\Users\Public\codebase-memory-cache","C:\Users\Public\codebase-memory-temp")) { New-Item -ItemType Directory -Force $dir | Out-Null }
$wrapperText = @'
@echo off
setlocal
if "%LOCALAPPDATA%"=="" set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
set "CBM_EXE=%LOCALAPPDATA%\Programs\codebase-memory-mcp\codebase-memory-mcp.exe"
set "CBM_CACHE_DIR=C:\Users\Public\codebase-memory-cache"
set "CBM_LOG_LEVEL=error"
set "CBM_DIAGNOSTICS=0"
set "TEMP=C:\Users\Public\codebase-memory-temp"
set "TMP=C:\Users\Public\codebase-memory-temp"
if not exist "%CBM_EXE%" (
  echo Codebase Memory executable not found: "%CBM_EXE%" 1>&2
  exit /b 127
)
"%CBM_EXE%" %*
'@
[System.IO.File]::WriteAllText($CbmWrapper,$wrapperText,$Utf8NoBom)
Write-Host "Wrapper written: $CbmWrapper"
if ($UpdateMcpConfig) {
  $cfgPath = "$env:USERPROFILE\.gemini\config\mcp_config.json"
  New-Item -ItemType Directory -Force (Split-Path $cfgPath -Parent) | Out-Null
  try { $cfg = [System.IO.File]::ReadAllText($cfgPath,$Utf8NoBom) | ConvertFrom-Json } catch { $cfg = [pscustomobject]@{mcpServers=[pscustomobject]@{}} }
  if (-not ($cfg.PSObject.Properties.Name -contains "mcpServers")) { $cfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([pscustomobject]@{}) }
  $servers=$cfg.mcpServers
  if ($servers.PSObject.Properties.Name -contains "codebase-memory") { $servers.PSObject.Properties.Remove("codebase-memory") }
  $servers | Add-Member -NotePropertyName "codebase-memory" -NotePropertyValue ([pscustomobject]@{command="C:\Windows\System32\cmd.exe"; args=@("/d","/c","C:\Users\Public\mcp-wrappers\codebase-memory-mcp.cmd")})
  [System.IO.File]::WriteAllText($cfgPath,($cfg|ConvertTo-Json -Depth 50),$Utf8NoBom)
  Write-Host "MCP config updated: $cfgPath"
}
