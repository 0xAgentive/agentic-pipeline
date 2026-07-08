$ErrorActionPreference = "Stop"

# Test-FastPatchAllowed.ps1
# v1.1.1b: path allowlist + added-line content guard.
#
# Purpose:
#   Allow /fastpatch only for small UI/styling diffs that do not introduce
#   dangerous imports, backend coupling, network/storage calls, or unsafe DOM APIs.
#
# Optional project override:
#   .agy/FASTPATCH_POLICY.json
#
# Example:
# {
#   "allowedPathRegex": [
#     "^src/frontend/components/AppSelect\\.tsx$",
#     "^src/frontend/components/OverlayRoot\\.tsx$",
#     "^src/frontend/.*\\.css$"
#   ],
#   "blockedAddedLineRegex": [
#     "^\\+.*dangerouslySetInnerHTML"
#   ]
# }

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $Root

function Read-JsonFile {
  param([string]$Path)

  if (Test-Path $Path) {
    return (Get-Content $Path -Raw | ConvertFrom-Json)
  }

  return $null
}

function Normalize-PathForRegex {
  param([string]$Path)

  return ($Path -replace "\\", "/")
}

function Get-ChangedFiles {
  $files = @()

  try {
    $files += git diff --name-only --
    $files += git diff --name-only --cached --
  } catch {
    Write-Host "git diff failed; fastpatch denied."
    exit 1
  }

  return @($files | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique)
}

function Get-AddedDiffLines {
  param([string[]]$Files)

  if (!$Files -or $Files.Count -eq 0) {
    return @()
  }

  $lines = @()

  foreach ($file in $Files) {
    $diff = git diff --unified=0 --no-ext-diff -- "$file"
    $diff += git diff --cached --unified=0 --no-ext-diff -- "$file"

    foreach ($line in $diff) {
      if ($line.StartsWith("+") -and -not $line.StartsWith("+++")) {
        $lines += [pscustomobject]@{
          File = $file
          Line = $line
        }
      }
    }
  }

  return @($lines)
}

$policy = Read-JsonFile ".agy\FASTPATCH_POLICY.json"

if ($policy -and $policy.allowedPathRegex) {
  $allowed = @($policy.allowedPathRegex)
} else {
  # Conservative default for UI/styling. Sensitive projects should override this
  # with a narrower .agy/FASTPATCH_POLICY.json.
  $allowed = @(
    '^src/frontend/components/[^/]+\.(tsx|jsx)$',
    '^src/frontend/styles/',
    '^src/frontend/.*\.css$',
    '^styles/',
    '^.*\.css$'
  )
}

$defaultBlockedAddedLineRegex = @(
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
  $blockedAddedLineRegex = @($defaultBlockedAddedLineRegex + $policy.blockedAddedLineRegex)
} else {
  $blockedAddedLineRegex = $defaultBlockedAddedLineRegex
}

$changed = Get-ChangedFiles

if ($changed.Count -eq 0) {
  Write-Host "No changed files. Fastpatch gate passes trivially."
  exit 0
}

$pathBlocked = @()

foreach ($file in $changed) {
  $norm = Normalize-PathForRegex $file
  $ok = $false

  foreach ($rx in $allowed) {
    if ($norm -match $rx) {
      $ok = $true
      break
    }
  }

  if (-not $ok) {
    $pathBlocked += $file
  }
}

if ($pathBlocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. These files are outside the approved allowlist:"
  $pathBlocked | ForEach-Object { Write-Host "- $_" }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

$addedLines = Get-AddedDiffLines -Files $changed
$contentBlocked = @()

foreach ($entry in $addedLines) {
  foreach ($rx in $blockedAddedLineRegex) {
    if ($entry.Line -match $rx) {
      $contentBlocked += [pscustomobject]@{
        File = $entry.File
        Pattern = $rx
        Line = $entry.Line
      }
      break
    }
  }
}

if ($contentBlocked.Count -gt 0) {
  Write-Host "FASTPATCH DENIED. Added lines match blocked content patterns:"
  foreach ($b in $contentBlocked) {
    Write-Host "- $($b.File): $($b.Line)"
  }
  Write-Host "Required next command: /auditphase or /nextphase"
  exit 1
}

Write-Host "FASTPATCH ALLOWED. Path and content guards passed:"
$changed | ForEach-Object { Write-Host "- $_" }
exit 0
