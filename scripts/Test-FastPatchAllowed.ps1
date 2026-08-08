param(
  [string]$RepoRoot = "",
  [switch]$RequireChanges,
  [int]$MaxChangedFiles = 3,
  [int]$MaxAddedLines = 80,
  [int]$MaxDeletedLines = 120
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'windows\common\NativeProcess.ps1')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

function Invoke-GitCapture {
  param([string[]]$GitArgs)
  $Native = Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList (@('-C', $Root) + $GitArgs)
  return [pscustomobject]@{
    Code = [int]$Native.ExitCode
    Lines = @($Native.StdOutLines)
    Text = [string]$Native.StdOut
    ErrorText = [string]$Native.StdErr
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-OptionalProperty {
  param([object]$Object,[string]$Name,[object]$Default=$null)
  if($null-eq$Object){return $Default}
  $Property=$Object.PSObject.Properties[$Name]
  if($null-eq$Property){return $Default}
  return $Property.Value
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
  $PolicyMaxChanged=Get-OptionalProperty $policy 'maxChangedFiles';if($null-ne$PolicyMaxChanged){$MaxChangedFiles=[int]$PolicyMaxChanged}
  $PolicyMaxAdded=Get-OptionalProperty $policy 'maxAddedLines';if($null-ne$PolicyMaxAdded){$MaxAddedLines=[int]$PolicyMaxAdded}
  $PolicyMaxDeleted=Get-OptionalProperty $policy 'maxDeletedLines';if($null-ne$PolicyMaxDeleted){$MaxDeletedLines=[int]$PolicyMaxDeleted}
}

$allowedPathRegex = @(
  '^src/frontend/components/[^/]+\.(tsx|jsx)$',
  '^src/frontend/styles/',
  '^src/frontend/.*\.css$',
  '^styles/',
  '^.*\.css$'
)

if ($policy -and (Get-OptionalProperty $policy 'allowedPathRegex')) {
  $allowedPathRegex = @(Get-OptionalProperty $policy 'allowedPathRegex')
}

$allowNewFiles = $false
if ($policy -and (Get-OptionalProperty $policy 'allowNewFiles' $false) -eq $true) {
  $allowNewFiles = $true
}

$allowedNewPathRegex = @()
if ($policy -and (Get-OptionalProperty $policy 'allowedNewPathRegex')) {
  $allowedNewPathRegex = @(Get-OptionalProperty $policy 'allowedNewPathRegex')
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

if ($policy -and (Get-OptionalProperty $policy 'blockedAddedLineRegex')) {
  $blockedAddedLineRegex = @($blockedAddedLineRegex + @(Get-OptionalProperty $policy 'blockedAddedLineRegex'))
}

$unstaged = Invoke-GitCapture @("diff", "--name-only", "-z", "--")
$staged = Invoke-GitCapture @("diff", "--name-only", "--cached", "-z", "--")
$untrackedResult = Invoke-GitCapture @("ls-files", "--others", "--exclude-standard", "-z")

if ($unstaged.Code -ne 0 -or $staged.Code -ne 0 -or $untrackedResult.Code -ne 0) {
  Write-Host "FASTPATCH DENIED. Git change discovery failed."
  Write-Host $unstaged.Text
  Write-Host $unstaged.ErrorText
  Write-Host $staged.Text
  Write-Host $staged.ErrorText
  Write-Host $untrackedResult.Text
  Write-Host $untrackedResult.ErrorText
  exit 1
}

$untracked = @(Split-AgenticNulList -Text $untrackedResult.Text)
[string[]]$changed = @(
  @((Split-AgenticNulList -Text $unstaged.Text) + (Split-AgenticNulList -Text $staged.Text) + $untracked) |
    Where-Object { $null -ne $_ -and $_.ToString().Length -gt 0 } |
    ForEach-Object { ($_.ToString() -replace '\\','/') } |
    Sort-Object -Unique
)

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
