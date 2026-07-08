param(
  [string]$TargetRoot = "$env:USERPROFILE\Documents\antigravity\H10 Athlete Cardio Lab",
  [string]$TemplateRoot = "$env:USERPROFILE\Documents\antigravity\_templates\agy-project-base",
  [switch]$UpdateMcpConfig
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaybookSrc = Join-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) "docs\AGENTIC_PIPELINE_PLAYBOOK.md"; if (!(Test-Path $PlaybookSrc)) { $PlaybookSrc = Join-Path $ScriptDir "agentic_pipeline_playbook_v1.1.1.md" }

function Write-Utf8File {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )
  $parent = Split-Path $Path -Parent
  if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Backup-IfExists {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (Test-Path -LiteralPath $Path) {
    Copy-Item -LiteralPath $Path -Destination "$Path.bak-v1.1.1-$Stamp" -Force
  }
}

function Patch-Workspace {
  param([Parameter(Mandatory=$true)][string]$Root)

  if (!(Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Host "[v1.1.1] Workspace not found, skipped: $Root"
    return
  }

  $Root = (Resolve-Path -LiteralPath $Root).Path
  Write-Host "[v1.1.1] Patching workspace: $Root"

  foreach ($dir in @(
    ".agents\workflows",
    ".agents\rules",
    "scripts",
    "docs",
    ".agy"
  )) {
    New-Item -ItemType Directory -Force (Join-Path $Root $dir) | Out-Null
  }

  if (Test-Path -LiteralPath $PlaybookSrc -PathType Leaf) {
    $dest = Join-Path $Root "docs\AGENTIC_PIPELINE_PLAYBOOK.md"
    Backup-IfExists $dest
    Copy-Item -LiteralPath $PlaybookSrc -Destination $dest -Force
  }

  $rule = Join-Path $Root ".agents\rules\51-v1.1.1-hotfix.md"
  Backup-IfExists $rule
  $ruleText = @'
# v1.1.1 Hotfix Governance

This workspace preserves the v1.1.0 phase-gated architecture.

## Deterministic verification
- LLM reports are not verification.
- Exit codes, diffs, tests, screenshots, and concrete logs are verification.
- For sensitive projects, /shipcheck must require deterministic semantic tests.

## Fastpatch
- /fastpatch is not model-authorized.
- /fastpatch is allowed only after scripts/Test-FastPatchAllowed.ps1 returns exit code 0.
- If the script fails, stop and use /auditphase or /nextphase.

## Codebase Memory on Windows
- Do not use CLI index_repository as the canonical path.
- Do not create mirrors, junctions, mklink, robocopy copies, subst drives, or C:\h10-athlete-cardio-lab.
- Use scripts/cbm-index-current-rpc.cjs if reindexing is needed.
'@
  Write-Utf8File -Path $rule -Text $ruleText

  $fast = Join-Path $Root ".agents\workflows\fastpatch.md"
  Backup-IfExists $fast
  $fastText = @'
---
description: Script-gated micro patch for approved low-risk UI/styling changes only.
---

# /fastpatch

Do not run planning, audit, codebase-map, or broad scans.

## Mandatory gate

Run first and again after edits:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1
```

If it returns non-zero, stop and require /auditphase or /nextphase.

## Allowed

- edit only files approved by Test-FastPatchAllowed.ps1;
- run targeted cheap checks;
- append one evidence-lite entry;
- stop.

## Forbidden

- backend, analytics, ingestion, source adapters, LLM Pack, reports, PDF, sanitizer, storage, DB, package/dependency/build config, hooks, workflows, MCP config, or release claims.

## Evidence-lite format

UTC:
Command:
Files:
Checks:
Result:
Risk class:
Next:
'@
  Write-Utf8File -Path $fast -Text $fastText

  $testFast = Join-Path $Root "scripts\Test-FastPatchAllowed.ps1"
  Backup-IfExists $testFast
  $testFastText = @'
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

$changed = @()
try {
  $changed += git diff --name-only --
  $changed += git diff --name-only --cached --
} catch {
  Write-Error "git diff failed; fastpatch denied"
  exit 1
}

$changed = $changed | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique

if ($changed.Count -eq 0) {
  Write-Host "No changed files. Fastpatch gate passes trivially."
  exit 0
}

# Conservative default for H10. Edit per project only after human review.
$allowed = @(
  '^src/frontend/components/AppSelect\.tsx$',
  '^src/frontend/components/OverlayRoot\.tsx$',
  '^src/frontend/styles/',
  '^src/frontend/.*\.css$'
)

$blocked = @()
foreach ($file in $changed) {
  $norm = $file -replace '\\','/'
  $ok = $false
  foreach ($rx in $allowed) {
    if ($norm -match $rx) { $ok = $true; break }
  }
  if (-not $ok) { $blocked += $file }
}

if ($blocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. These files are outside the approved allowlist:"
  $blocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

Write-Host "FASTPATCH ALLOWED. Changed files are inside the approved allowlist:"
$changed | ForEach-Object { Write-Host "- $_" }
exit 0
'@
  Write-Utf8File -Path $testFast -Text $testFastText

  $codebaseMap = Join-Path $Root ".agents\workflows\codebase-map.md"
  Backup-IfExists $codebaseMap
  $codebaseMapText = @'
---
description: Use Codebase Memory if available, otherwise produce a manual structural map without implementation.
---

# /codebase-map

Do not implement features.
Do not modify source files.

## Windows Codebase Memory policy

- Do not use CLI index_repository.
- Do not create mirrors, junctions, mklink, robocopy duplicates, subst drives, or C:\h10-athlete-cardio-lab.
- If reindexing is needed, use: node .\scripts\cbm-index-current-rpc.cjs
- Prefer existing index and query tools first: list_projects, index_status, search_code, search_graph, get_architecture, trace_path.

## Output

Report MCP visibility, list_projects result, whether existing RPC index was used, key modules, risks, sensitive boundaries, likely audit files, and exact next command.

The exact next command should normally be /auditphase.

Stop after the map.
'@
  Write-Utf8File -Path $codebaseMap -Text $codebaseMapText

  Write-Host "[v1.1.1] Workspace patched: $Root"
}

Patch-Workspace -Root $TemplateRoot
Patch-Workspace -Root $TargetRoot

if ($UpdateMcpConfig) {
  $WrapperDir = "C:\Users\Public\mcp-wrappers"
  $CbmWrapper = Join-Path $WrapperDir "codebase-memory-mcp.cmd"
  $CbmCache = "C:\Users\Public\codebase-memory-cache"
  $CbmTemp = "C:\Users\Public\codebase-memory-temp"

  foreach ($dir in @($WrapperDir, $CbmCache, $CbmTemp)) {
    New-Item -ItemType Directory -Force $dir | Out-Null
  }

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
  Write-Utf8File -Path $CbmWrapper -Text $wrapperText

  $cfgPaths = @(
    "$env:USERPROFILE\.gemini\config\mcp_config.json",
    "$env:USERPROFILE\.gemini\antigravity\mcp_config.json"
  ) | Where-Object { Test-Path $_ }

  if ($cfgPaths.Count -eq 0) {
    $cfgPaths = @("$env:USERPROFILE\.gemini\config\mcp_config.json")
    New-Item -ItemType Directory -Force (Split-Path $cfgPaths[0] -Parent) | Out-Null
    $cfg = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
    [System.IO.File]::WriteAllText($cfgPaths[0], ($cfg | ConvertTo-Json -Depth 50), $Utf8NoBom)
  }

  foreach ($cfgPath in $cfgPaths) {
    Backup-IfExists $cfgPath
    try {
      $raw = [System.IO.File]::ReadAllText($cfgPath, $Utf8NoBom)
      $cfg = $raw | ConvertFrom-Json
    } catch {
      $cfg = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
    }

    if (-not ($cfg.PSObject.Properties.Name -contains "mcpServers")) {
      $cfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([pscustomobject]@{})
    }

    $servers = $cfg.mcpServers
    if ($servers.PSObject.Properties.Name -contains "codebase-memory") {
      $servers.PSObject.Properties.Remove("codebase-memory")
    }

    $servers | Add-Member -NotePropertyName "codebase-memory" -NotePropertyValue ([pscustomobject]@{
      command = "C:\Windows\System32\cmd.exe"
      args = @("/d", "/c", "C:\Users\Public\mcp-wrappers\codebase-memory-mcp.cmd")
    })

    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 50), $Utf8NoBom)
    Write-Host "[v1.1.1] MCP config updated: $cfgPath"
  }
}

Write-Host "v1.1.1 hotfix applied."
