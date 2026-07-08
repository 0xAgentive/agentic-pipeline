param(
  [string]$RepoRoot = ".",
  [switch]$Strict
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path $RepoRoot).Path
Set-Location $RepoRoot

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-ErrorMessage { param([string]$Message) $script:errors.Add($Message) | Out-Null }
function Add-WarningMessage { param([string]$Message) $script:warnings.Add($Message) | Out-Null }
function Test-RequiredPath { param([string]$Path) if (!(Test-Path $Path)) { Add-ErrorMessage "Missing required path: $Path" } }

$required = @(
  "README.md",
  "LICENSE",
  "SECURITY.md",
  "CONTRIBUTING.md",
  "CHANGELOG.md",
  "docs\AGENTIC_PIPELINE_PLAYBOOK.md",
  "templates\agy-project-base\.agents\AGENTS.md",
  "templates\agy-project-base\.agy\PHASE_STATUS.json",
  "templates\agy-project-base\.cbmignore",
  "templates\agy-project-base\scripts\Test-FastPatchAllowed.ps1",
  "templates\agy-project-base\scripts\cbm-index-current-rpc.cjs",
  "templates\agy-project-base\scripts\cbm-wrapper-smoke.cjs",
  "scripts\cbm-index-current-rpc.cjs",
  "scripts\cbm-wrapper-smoke.cjs",
  "scripts\windows\Validate-AgenticPipelinePackage.ps1",
  ".github\workflows\validate.yml"
)

foreach ($path in $required) { Test-RequiredPath $path }

# PowerShell parse check.
$psFiles = Get-ChildItem -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\.git\\|/\.git/' }
foreach ($file in $psFiles) {
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
  if ($parseErrors.Count -gt 0) {
    foreach ($err in $parseErrors) { Add-ErrorMessage "PowerShell parse error in $($file.FullName): $($err.Message)" }
  }
}

# JSON parse check for state/config files.
$jsonCandidates = @(
  "templates\agy-project-base\.agy\PHASE_STATUS.json",
  ".agy\GITHUB_PROFILE.json",
  "package.json"
) | Where-Object { Test-Path $_ }

foreach ($json in $jsonCandidates) {
  try { Get-Content $json -Raw | ConvertFrom-Json | Out-Null }
  catch { Add-ErrorMessage "Invalid JSON: $json - $($_.Exception.Message)" }
}

# .cbmignore baseline check.
$baseline = @(
  "node_modules/", "dist/", "build/", "coverage/", ".next/", ".nuxt/", ".turbo/", ".vite/", ".git/", ".agy/checkpoints/", ".pipeline_patch_backup/", ".pipeline_sync_backup/", ".pipeline_v1_1_backup/", ".pipeline_adopt_backup/", ".codebase-memory/", "playwright-report/", "test-results/", "artifacts/", "reports/generated/", "logs/", "tmp/", "temp/", "*.log", "*.zip", "*.pdf", "*.html", "*.har", "*.trace"
)

foreach ($cbm in @(".cbmignore", "templates\agy-project-base\.cbmignore")) {
  if (Test-Path $cbm) {
    $text = Get-Content $cbm -Raw
    foreach ($entry in $baseline) {
      if ($text -notmatch [regex]::Escape($entry)) { Add-ErrorMessage "$cbm missing baseline entry: $entry" }
    }
  }
}

# Placeholder hook check.
$hookDir = "templates\agy-project-base\.agents\hooks"
if (Test-Path $hookDir) {
  $hookFiles = Get-ChildItem $hookDir -File -Filter *.ps1
  foreach ($hook in $hookFiles) {
    $t = (Get-Content $hook.FullName -Raw).Trim()
    if ($t -eq 'Write-Output "{}"' -or $t -eq "Write-Output '{}'" -or $t -match 'placeholder OK') {
      Add-ErrorMessage "Placeholder/no-op hook found: $($hook.FullName)"
    }
  }
} else {
  Add-ErrorMessage "Missing template hook directory: $hookDir"
}

# Reference integrity for known historical drift.
$playbook = "docs\AGENTIC_PIPELINE_PLAYBOOK.md"
if (Test-Path $playbook) {
  $text = Get-Content $playbook -Raw
  if ($text -match 'scripts/cbm-index-current-rpc\.cjs' -and !(Test-Path "scripts\cbm-index-current-rpc.cjs")) {
    Add-ErrorMessage "Playbook references scripts/cbm-index-current-rpc.cjs, but file is missing."
  }
  if ($text -match 'scripts/cbm-wrapper-smoke\.cjs' -and !(Test-Path "scripts\cbm-wrapper-smoke.cjs")) {
    Add-ErrorMessage "Playbook references scripts/cbm-wrapper-smoke.cjs, but file is missing."
  }
}

$legacyInstaller = "scripts\windows\Apply-AgenticPipeline-v1.1.1.ps1"
if (Test-Path $legacyInstaller) {
  $installerText = Get-Content $legacyInstaller -Raw
  if ($installerText -match 'agentic_pipeline_playbook_v1\.1\.1\.md' -and !(Test-Path "scripts\windows\agentic_pipeline_playbook_v1.1.1.md")) {
    Add-ErrorMessage "$legacyInstaller references missing scripts/windows/agentic_pipeline_playbook_v1.1.1.md. Patch the installer or include the file."
  }
}

if ($warnings.Count -gt 0) {
  Write-Host "Warnings:"
  $warnings | ForEach-Object { Write-Host "- $_" }
}

if ($errors.Count -gt 0) {
  Write-Host "Validation failed:"
  $errors | ForEach-Object { Write-Host "- $_" }
  exit 1
}

Write-Host "Hard package validation passed."
exit 0
