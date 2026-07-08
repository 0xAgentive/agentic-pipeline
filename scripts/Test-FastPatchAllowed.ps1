param(
  [switch]$RequireChanges,
  [int]$MaxFiles = 3,
  [int]$MaxAddedLines = 80,
  [int]$MaxDeletedLines = 120
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Invoke-GitLines {
  param([string[]]$Args)
  $out = & git @Args 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host $out
    throw "git command failed: git $($Args -join ' ')"
  }
  return @($out)
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

$inside = $false
try {
  $insideText = Invoke-GitLines @("rev-parse", "--is-inside-work-tree")
  if (($insideText -join "").Trim() -eq "true") { $inside = $true }
} catch {}
if (-not $inside) {
  Write-Host "FASTPATCH DENIED. Not inside a Git worktree."
  exit 1
}

$files = @()
$files += Invoke-GitLines @("diff", "--name-only", "--")
$files += Invoke-GitLines @("diff", "--name-only", "--cached", "--")
$files += Invoke-GitLines @("ls-files", "--others", "--exclude-standard")
$files = $files | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Sort-Object -Unique

if ($files.Count -eq 0) {
  if ($RequireChanges) {
    Write-Host "FASTPATCH DENIED. No changed files found for mandatory post-edit gate."
    exit 1
  }
  Write-Host "No changed files. Fastpatch preflight passes only as a clean-start check. Run again after edits with -RequireChanges."
  exit 0
}

if ($files.Count -gt $MaxFiles) {
  Write-Host "FASTPATCH DENIED. Too many changed files: $($files.Count), limit: $MaxFiles"
  $files | ForEach-Object { Write-Host "- $_" }
  exit 1
}

$allowed = @(
  '^src/frontend/components/AppSelect\.tsx$',
  '^src/frontend/components/OverlayRoot\.tsx$',
  '^src/frontend/styles/',
  '^src/frontend/.*\.css$'
)

$blocked = @()
foreach ($file in $files) {
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

$forbiddenPatterns = @(
  'from\s+["''].*(backend|analytics|llmPack|reports|sources|ingestion|db|server|security|qcThresholds|metricDefinitions).*?["'']',
  'import\s*\(\s*["''].*(backend|analytics|llmPack|reports|sources|ingestion|db|server|security).*?["'']\s*\)',
  '\bfetch\s*\(',
  '\bWebSocket\b',
  '\blocalStorage\b',
  '\bsessionStorage\b',
  '\bdocument\.cookie\b',
  '\bdangerouslySetInnerHTML\b',
  '\binnerHTML\b',
  '\beval\s*\(',
  '\bFunction\s*\(',
  '\bchild_process\b',
  '\bnode:child_process\b',
  '\bfs\b',
  '\bnode:fs\b',
  '\bprocess\.env\b'
)

$addedLines = New-Object System.Collections.Generic.List[string]
$deletedCount = 0
$trackedFiles = Invoke-GitLines @("ls-files")
$trackedSet = @{}
foreach ($tf in $trackedFiles) { $trackedSet[$tf] = $true }

$diff = Invoke-GitLines @("diff", "--cached", "--unified=0", "--")
$diff += Invoke-GitLines @("diff", "--unified=0", "--")

foreach ($line in $diff) {
  if ($line.StartsWith("+++") -or $line.StartsWith("---")) { continue }
  if ($line.StartsWith("+")) { [void]$addedLines.Add($line.Substring(1)) }
  elseif ($line.StartsWith("-")) { $deletedCount++ }
}

foreach ($file in $files) {
  if (-not $trackedSet.ContainsKey($file)) {
    if ($file -match '\.tsx?$|\.jsx?$|\.css$|\.md$|\.json$') {
      $path = Join-Path $Root $file
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
          [void]$addedLines.Add($line)
        }
      }
    } else {
      Write-Host "FASTPATCH DENIED. New untracked file type is not allowed: $file"
      exit 1
    }
  }
}

if ($addedLines.Count -gt $MaxAddedLines) {
  Write-Host "FASTPATCH DENIED. Too many added lines: $($addedLines.Count), limit: $MaxAddedLines"
  exit 1
}

if ($deletedCount -gt $MaxDeletedLines) {
  Write-Host "FASTPATCH DENIED. Too many deleted lines: $deletedCount, limit: $MaxDeletedLines"
  exit 1
}

$violations = @()
foreach ($line in $addedLines) {
  foreach ($rx in $forbiddenPatterns) {
    if ($line -match $rx) {
      $violations += $line.Trim()
      break
    }
  }
}

if ($violations.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. Added lines contain forbidden imports or risky APIs:"
  $violations | Select-Object -First 20 | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

Write-Host "FASTPATCH ALLOWED. Final changed files and added lines are inside the approved limits."
$files | ForEach-Object { Write-Host "- $_" }
exit 0
