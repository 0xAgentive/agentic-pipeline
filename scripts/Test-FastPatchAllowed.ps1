param(
  [string]$RepoRoot = "",
  [switch]$RequireChanges,
  [int]$MaxChangedFiles = 3,
  [int]$MaxAddedLines = 80,
  [int]$MaxDeletedLines = 120
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

function Invoke-GitCapture {
  param([string[]]$GitArgs)

  # AGY_NATIVE_STDERR_SAFE
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& git -C $Root @GitArgs 2>&1)
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
  }

  return [pscustomobject]@{
    Code = $code
    Lines = @($output)
    Text = (@($output) -join "`n")
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$inside = Invoke-GitCapture @("rev-parse", "--is-inside-work-tree")
if ($inside.Code -ne 0 -or $inside.Text.Trim() -ne "true") {
  Write-Host "FASTPATCH DENIED. Not inside a Git worktree: $Root"
  exit 1
}

$policyPath = Join-Path $Root ".agy\FASTPATCH_POLICY.json"
$policy = $null
try {
  $policy = Read-JsonFile $policyPath
} catch {
  Write-Host "FASTPATCH DENIED. Invalid policy JSON: $policyPath"
  Write-Host $_.Exception.Message
  exit 1
}

if ($policy) {
  if ($policy.maxChangedFiles -ne $null) { $MaxChangedFiles = [int]$policy.maxChangedFiles }
  if ($policy.maxAddedLines -ne $null) { $MaxAddedLines = [int]$policy.maxAddedLines }
  if ($policy.maxDeletedLines -ne $null) { $MaxDeletedLines = [int]$policy.maxDeletedLines }
}

$allowedPathRegex = @(
  '^src/frontend/components/[^/]+\.(tsx|jsx)$',
  '^src/frontend/styles/',
  '^src/frontend/.*\.css$',
  '^styles/',
  '^.*\.css$'
)

if ($policy -and $policy.allowedPathRegex) {
  $allowedPathRegex = @($policy.allowedPathRegex)
}

$allowNewFiles = $false
if ($policy -and $policy.allowNewFiles -eq $true) {
  $allowNewFiles = $true
}

$allowedNewPathRegex = @()
if ($policy -and $policy.allowedNewPathRegex) {
  $allowedNewPathRegex = @($policy.allowedNewPathRegex)
}

$blockedAddedLineRegex = @(
  '^\+\s*import\s+.*\s+from\s+["''].*(\.\./\.\./backend|\.\./backend|/backend/|backend/|analytics|llmPack|reports|sources|ingestion|/db/|shared/(qc|security|redaction|sanit|crypto))',
  '^\+\s*import\s*\(',
  '^\+.*\brequire\s*\(',
  '^\+.*\bdangerouslySetInnerHTML\b',
  '^\+.*\binnerHTML\b',
  '^\+.*\beval\s*\(',
  '^\+.*\bnew\s+Function\s*\(',
  '^\+.*\bdocument\.cookie\b',
  '^\+.*\blocalStorage\b',
  '^\+.*\bsessionStorage\b',
  '^\+.*\bfetch\s*\(',
  '^\+.*\bXMLHttpRequest\b',
  '^\+.*\bnew\s+WebSocket\s*\(',
  '^\+.*\bchild_process\b',
  '^\+.*\bprocess\.env\b',
  '^\+.*\bfrom\s+["'']fs["'']',
  '^\+.*\bfrom\s+["'']node:fs["'']'
)

if ($policy -and $policy.blockedAddedLineRegex) {
  $blockedAddedLineRegex = @($blockedAddedLineRegex + @($policy.blockedAddedLineRegex))
}

$unstaged = Invoke-GitCapture @("diff", "--name-only", "--")
$staged = Invoke-GitCapture @("diff", "--name-only", "--cached", "--")
$untrackedResult = Invoke-GitCapture @("ls-files", "--others", "--exclude-standard")

if ($unstaged.Code -ne 0 -or $staged.Code -ne 0 -or $untrackedResult.Code -ne 0) {
  Write-Host "FASTPATCH DENIED. Git change discovery failed."
  Write-Host $unstaged.Text
  Write-Host $staged.Text
  Write-Host $untrackedResult.Text
  exit 1
}

$untracked = @($untrackedResult.Lines | Where-Object { $_ -and $_.ToString().Trim() } | ForEach-Object { $_.ToString().Trim() })
$changed = @($unstaged.Lines + $staged.Lines + $untracked) |
  Where-Object { $_ -and $_.ToString().Trim() } |
  ForEach-Object { ($_.ToString().Trim() -replace '\\','/') } |
  Sort-Object -Unique

if ($changed.Count -eq 0) {
  if ($RequireChanges) {
    Write-Host "FASTPATCH DENIED. -RequireChanges was specified, but no diff exists."
    exit 1
  }

  Write-Host "FASTPATCH PREFLIGHT ONLY. No changed files detected."
  Write-Host "Run this gate again after edits with -RequireChanges before reporting success."
  exit 0
}

if ($changed.Count -gt $MaxChangedFiles) {
  Write-Host "FASTPATCH DENIED. Too many changed files: $($changed.Count). Max allowed: $MaxChangedFiles"
  $changed | ForEach-Object { Write-Host "- $_" }
  exit 1
}

$untrackedSet = @{}
foreach ($file in $untracked) {
  $untrackedSet[($file -replace '\\','/')] = $true
}

$pathBlocked = @()
$newFileBlocked = @()

foreach ($file in $changed) {
  $pathAllowed = $false
  foreach ($rx in $allowedPathRegex) {
    if ($file -match $rx) {
      $pathAllowed = $true
      break
    }
  }

  if (!$pathAllowed) {
    $pathBlocked += $file
    continue
  }

  if ($untrackedSet.ContainsKey($file)) {
    $newAllowed = $allowNewFiles
    if (!$newAllowed -and $allowedNewPathRegex.Count -gt 0) {
      foreach ($rx in $allowedNewPathRegex) {
        if ($file -match $rx) {
          $newAllowed = $true
          break
        }
      }
    }

    if (!$newAllowed) {
      $newFileBlocked += $file
    }
  }
}

if ($pathBlocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. Files outside approved allowlist:"
  $pathBlocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

if ($newFileBlocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. New files are blocked unless explicitly allowed by .agy/FASTPATCH_POLICY.json:"
  $newFileBlocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

$added = 0
$deleted = 0
$contentBlocked = @()

foreach ($file in $changed) {
  $patchLines = @()

  $diffUnstaged = Invoke-GitCapture @("diff", "--unified=0", "--no-ext-diff", "--", $file)
  if ($diffUnstaged.Code -eq 0) { $patchLines += $diffUnstaged.Lines }

  $diffStaged = Invoke-GitCapture @("diff", "--cached", "--unified=0", "--no-ext-diff", "--", $file)
  if ($diffStaged.Code -eq 0) { $patchLines += $diffStaged.Lines }

  if ($untrackedSet.ContainsKey($file)) {
    $fullPath = Join-Path $Root ($file -replace '/','\')
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
      Get-Content -LiteralPath $fullPath -ErrorAction SilentlyContinue | ForEach-Object {
        $patchLines += ("+" + $_)
      }
    }
  }

  foreach ($lineObject in $patchLines) {
    $line = $lineObject.ToString()
    if ($line.StartsWith("+++") -or $line.StartsWith("---")) { continue }

    if ($line.StartsWith("+")) {
      $added++
      foreach ($rx in $blockedAddedLineRegex) {
        if ($line -match $rx) {
          $contentBlocked += "$file :: $line"
          break
        }
      }
    } elseif ($line.StartsWith("-")) {
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

if ($contentBlocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. Dangerous added content detected:"
  $contentBlocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

Write-Host "FASTPATCH ALLOWED. Guard checks passed."
Write-Host "Changed files: $($changed.Count); added lines: $added; deleted lines: $deleted"
$changed | ForEach-Object { Write-Host "- $_" }
exit 0
