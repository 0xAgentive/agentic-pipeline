$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
$Errors = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$m) {
  [void]$Errors.Add($m)
}

# 1. Protected root docs exist
$protectedRootDocs = @(
  "docs/AGENTIC_PIPELINE_PLAYBOOK.md"
  "docs/GITHUB_PUBLICATION.md"
  "docs/AUDIT_CHECKLIST.md"
  "docs/PIPELINE_VERSION_MATRIX.md"
)
foreach ($p in $protectedRootDocs) {
  $full = Join-Path $RepoRoot $p
  if (!(Test-Path -LiteralPath $full)) {
    Add-Err "Missing protected root doc: $p"
  }
}

# 2. Docs IA folders exist
$iaFolders = @(
  "docs/guides"
  "docs/concepts"
  "docs/reference"
  "docs/maintainers"
  "docs/archive"
)
foreach ($folder in $iaFolders) {
  $full = Join-Path $RepoRoot $folder
  if (!(Test-Path -LiteralPath $full -PathType Container)) {
    Add-Err "Missing docs IA folder: $folder"
  }
}

# 3. README.md and README.ru.md exist in the root
$readmes = @("README.md", "README.ru.md")
foreach ($readme in $readmes) {
  $full = Join-Path $RepoRoot $readme
  if (!(Test-Path -LiteralPath $full)) {
    Add-Err "Missing root readme: $readme"
  }
}

# 4. README_RU.md is absent or a redirect stub
$readmeRuOld = Join-Path $RepoRoot "README_RU.md"
if (Test-Path -LiteralPath $readmeRuOld) {
  $txt = Get-Content -LiteralPath $readmeRuOld -Encoding utf8 -Raw
  if ($txt -notmatch "README\.ru\.md") {
    Add-Err "README_RU.md exists but is not a redirect stub to README.ru.md"
  }
}

# 5. docs/agentic-pipeline.zip and agentic-pipeline.zip are absent
$zips = @("agentic-pipeline.zip", "docs/agentic-pipeline.zip")
foreach ($zip in $zips) {
  $full = Join-Path $RepoRoot $zip
  if (Test-Path -LiteralPath $full) {
    Add-Err "Junk zip file must be deleted: $zip"
  }
}

# 6. docs/reference/PIPELINE_VERSION_MATRIX.md is not stale
$canonicalMatrix = Join-Path $RepoRoot "docs/PIPELINE_VERSION_MATRIX.md"
$refMatrix = Join-Path $RepoRoot "docs/reference/PIPELINE_VERSION_MATRIX.md"
if (Test-Path -LiteralPath $refMatrix) {
  $cText = Get-Content -LiteralPath $canonicalMatrix -Encoding utf8 -Raw
  $rText = Get-Content -LiteralPath $refMatrix -Encoding utf8 -Raw
  if ($cText -ne $rText) {
    Add-Err "docs/reference/PIPELINE_VERSION_MATRIX.md is stale (does not match canonical docs/PIPELINE_VERSION_MATRIX.md)"
  }
}

# 7. Local markdown links in README.md, README.ru.md and docs/*.md resolve
$filesToCheck = Get-ChildItem -Path $RepoRoot -Filter *.md -File
$filesToCheck += Get-ChildItem -Path (Join-Path $RepoRoot "docs") -Filter *.md -File -Recurse | Where-Object {
  $_.FullName -notmatch "docs[/\\]archive"
}

Write-Host "Checking links in $($filesToCheck.Count) markdown files..."

foreach ($file in $filesToCheck) {
  $content = Get-Content -LiteralPath $file.FullName -Encoding utf8 -Raw
  # Match [text](url) where url does not have http/https
  $LinkMatches = [regex]::Matches($content, '\[[^\]]*\]\(([^)]+)\)')
  foreach ($match in $LinkMatches) {
    $url = $match.Groups[1].Value.Trim()
    
    # Skip web links, email links, anchors
    if ($url.StartsWith("http://") -or $url.StartsWith("https://") -or $url.StartsWith("mailto:") -or $url.StartsWith("#")) {
      continue
    }
    
    # If the URL contains an anchor/line number, strip it
    $urlClean = $url -replace '#.*$', ''
    if (!$urlClean) { continue }
    
    # URL decode
    $decodedUrl = [System.Uri]::UnescapeDataString($urlClean)
    
    # Resolve to absolute local path
    $resolvedPath = $null
    if ($decodedUrl.StartsWith("file:///")) {
      $resolvedPath = $decodedUrl -replace '^file:///', ''
      # On Windows, replace forward slash with backslash for file system check
      $resolvedPath = $resolvedPath -replace '/', '\'
      # Sometimes file:/// paths omit drive colon or have extra slashes, let's fix
      if ($resolvedPath -match '^[a-zA-Z]:') {
        # Valid absolute Windows path
      } else {
        # Relative to root/host
        $resolvedPath = Join-Path $RepoRoot $resolvedPath
      }
    } else {
      # Relative to the containing file's directory
      $dir = Split-Path -Path $file.FullName
      $resolvedPath = Join-Path $dir $decodedUrl
    }
    
    # Normalize path
    try {
      if (Test-Path -LiteralPath $resolvedPath) {
        # Resolves successfully!
      } else {
        # Check if maybe we can check relative to repo root
        $altPath = Join-Path $RepoRoot $decodedUrl
        if (Test-Path -LiteralPath $altPath) {
          # Resolves via repo root fallback
        } else {
          $relFile = $file.FullName.Substring($RepoRoot.Length).TrimStart("\","/")
          Add-Err "Broken link in [$relFile]: '$url' (Resolved path not found: $resolvedPath)"
        }
      }
    } catch {
      $relFile = $file.FullName.Substring($RepoRoot.Length).TrimStart("\","/")
      Add-Err "Invalid path resolution for link in [$relFile]: '$url' ($resolvedPath)"
    }
  }
}

if ($Errors.Count -gt 0) {
  Write-Host "Human Docs validation failed:" -ForegroundColor Red
  $Errors | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
  exit 1
}

Write-Host "Human Docs validation passed." -ForegroundColor Green
exit 0

# AGY_NO_FILE_URI_GUARD_START
# Reject local file:// links in active public documentation.
$ActiveMarkdownForFileUriGuard = @()

foreach ($Path in @("README.md", "README.ru.md", "README_RU.md")) {
  if (Test-Path $Path) {
    $ActiveMarkdownForFileUriGuard += Get-Item $Path
  }
}

if (Test-Path "docs") {
  $ActiveMarkdownForFileUriGuard += Get-ChildItem docs -Recurse -File -Include "*.md" |
    Where-Object { $_.FullName -notmatch "\\docs\\archive\\legacy-root-docs-" }
}

$FileUriHits = @()

foreach ($File in ($ActiveMarkdownForFileUriGuard | Sort-Object FullName -Unique)) {
  $Hits = Select-String -Path $File.FullName -Pattern "file:///" -SimpleMatch -ErrorAction SilentlyContinue
  foreach ($Hit in $Hits) {
    $FileUriHits += "$($File.FullName):$($Hit.LineNumber): $($Hit.Line.Trim())"
  }
}

if ($FileUriHits.Count -gt 0) {
  Write-Host ""
  Write-Host "[file-uri-check] Local file:/// links are forbidden in active public docs:"
  $FileUriHits | ForEach-Object { Write-Host "  $_" }
  throw "Forbidden file:/// links found: $($FileUriHits.Count)"
}
# AGY_NO_FILE_URI_GUARD_END
