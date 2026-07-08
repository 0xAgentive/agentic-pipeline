param(
  [string]$RepoRoot = "",
  [int]$MaxChangedFiles = 3,
  [int]$MaxAddedLines = 80,
  [int]$MaxDeletedLines = 120
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

function Run-GitLines {
  param([string[]]$ArgumentList)

  $output = & git -C $Root @ArgumentList 2>&1
  $code = $LASTEXITCODE

  return [pscustomobject]@{
    Code = $code
    Output = @($output)
  }
}

$inside = Run-GitLines @("rev-parse", "--is-inside-work-tree")
if ($inside.Code -ne 0 -or (($inside.Output -join "`n") -notmatch "true")) {
  Write-Host "FASTPATCH DENIED. Not inside a Git worktree: $Root"
  exit 1
}

$changed = @()
$changed += (Run-GitLines @("diff", "--name-only", "--")).Output
$changed += (Run-GitLines @("diff", "--name-only", "--cached", "--")).Output
$untracked = (Run-GitLines @("ls-files", "--others", "--exclude-standard")).Output
$changed += $untracked

$changed = $changed |
  Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 } |
  ForEach-Object { $_.ToString().Trim() } |
  Sort-Object -Unique

$untrackedSet = @{}
foreach ($u in $untracked) {
  if ($u -and $u.ToString().Trim().Length -gt 0) {
    $untrackedSet[$u.ToString().Trim()] = $true
  }
}

if ($changed.Count -eq 0) {
  Write-Host "FASTPATCH PREFLIGHT ONLY. No changed files detected."
  Write-Host "This is not enough for completion; run this gate again after edits."
  exit 0
}

if ($changed.Count -gt $MaxChangedFiles) {
  Write-Host "FASTPATCH DENIED. Too many changed files: $($changed.Count). Max allowed: $MaxChangedFiles"
  $changed | ForEach-Object { Write-Host "- $_" }
  exit 1
}

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
    if ($norm -match $rx) {
      $ok = $true
      break
    }
  }

  if (-not $ok) {
    $blocked += $file
  }
}

if ($blocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. These files are outside the approved allowlist:"
  $blocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

$dangerPatterns = @(
  '^\+\s*import\s+.*(\.\./.*backend|\.\./.*server|\.\./.*db|\.\./.*analytics|\.\./.*llmPack|\.\./.*reports|\.\./.*sources|\.\./.*ingestion)',
  '^\+\s*import\s+.*(backend/|server/|db/|analytics/|llmPack/|reports/|sources/|ingestion/)',
  '^\+.*\bfetch\s*\(',
  '^\+.*\bXMLHttpRequest\b',
  '^\+.*\bWebSocket\b',
  '^\+.*\blocalStorage\b',
  '^\+.*\bsessionStorage\b',
  '^\+.*\bdocument\.cookie\b',
  '^\+.*\bdangerouslySetInnerHTML\b',
  '^\+.*\binnerHTML\b',
  '^\+.*\beval\s*\(',
  '^\+.*\bFunction\s*\(',
  '^\+.*\bchild_process\b',
  '^\+.*\bprocess\.env\b',
  '^\+.*\bfs\b'
)

$added = 0
$deleted = 0
$danger = @()

foreach ($file in $changed) {
  $patchLines = @()

  $diff1 = Run-GitLines @("diff", "--unified=0", "--", $file)
  if ($diff1.Code -eq 0) {
    $patchLines += $diff1.Output
  }

  $diff2 = Run-GitLines @("diff", "--cached", "--unified=0", "--", $file)
  if ($diff2.Code -eq 0) {
    $patchLines += $diff2.Output
  }

  if ($untrackedSet.ContainsKey($file)) {
    $full = Join-Path $Root $file
    if (Test-Path -LiteralPath $full -PathType Leaf) {
      Get-Content -LiteralPath $full -ErrorAction SilentlyContinue | ForEach-Object {
        $patchLines += ("+" + $_)
      }
    }
  }

  foreach ($line in $patchLines) {
    $s = $line.ToString()

    if ($s.StartsWith("+++") -or $s.StartsWith("---")) {
      continue
    }

    if ($s.StartsWith("+")) {
      $added++

      foreach ($rx in $dangerPatterns) {
        if ($s -match $rx) {
          $danger += "$file :: $s"
          break
        }
      }
    } elseif ($s.StartsWith("-")) {
      $deleted++
    }
  }
}

if ($added -gt $MaxAddedLines) {
  Write-Host "FASTPATCH DENIED. Added lines: $added. Max allowed: $MaxAddedLines"
  exit 1
}

if ($deleted -gt $MaxDeletedLines) {
  Write-Host "FASTPATCH DENIED. Deleted lines: $deleted. Max allowed: $MaxDeletedLines"
  exit 1
}

if ($danger.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. Dangerous added lines detected:"
  $danger | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

Write-Host "FASTPATCH ALLOWED. Changed files are inside the allowlist and added content passed guard checks:"
$changed | ForEach-Object { Write-Host "- $_" }
exit 0