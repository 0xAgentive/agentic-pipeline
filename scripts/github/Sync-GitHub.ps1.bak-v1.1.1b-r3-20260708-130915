param(
  [string]$Repo = "",
  [ValidateSet("direct", "pr")]
  [string]$Mode = "",
  [ValidateSet("public", "private", "internal")]
  [string]$Visibility = "",
  [string]$Branch = "",
  [string]$Message = "",
  [switch]$SkipChecks
)

$ErrorActionPreference = "Stop"

function Require-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (Test-Path $Path) {
    return (Get-Content $Path -Raw | ConvertFrom-Json)
  }
  return $null
}

function Assert-Not-UserProfileRoot {
  $cwd = (Resolve-Path ".").Path
  $UserProfileRoot = (Resolve-Path $env:USERPROFILE).Path

  if ($cwd -eq $UserProfileRoot) {
    throw "Refusing to publish from user profile root: $cwd"
  }
}

function Run-NpmScriptIfExists {
  param([string]$Name)

  if (!(Test-Path "package.json")) { return }

  $pkg = Get-Content "package.json" -Raw | ConvertFrom-Json
  if ($pkg.scripts -and ($pkg.scripts.PSObject.Properties.Name -contains $Name)) {
    Write-Host "Running npm run $Name"
    npm run $Name
  }
}

function Assert-NoDangerousStagedFiles {
  $staged = git diff --cached --name-only

  $denyPatterns = @(
    '(^|/)\.env($|\.)',
    '\.pem$',
    '\.key$',
    '\.pfx$',
    '\.p12$',
    '\.sqlite$',
    '\.db$',
    '(^|/)node_modules/',
    '(^|/)dist/',
    '(^|/)build/',
    '(^|/)\.agy/',
    '(^|/)\.codebase-memory/',
    '\.log$',
    '\.zip$',
    '\.har$',
    '\.trace$'
  )

  $bad = @()

  foreach ($file in $staged) {
    if ($file -eq ".agy/GITHUB_PROFILE.json" -or $file -eq ".agy\GITHUB_PROFILE.json") {
      continue
    }

    foreach ($pattern in $denyPatterns) {
      if ($file -match $pattern) {
        $bad += $file
        break
      }
    }
  }

  if ($bad.Count -gt 0) {
    Write-Host "Refusing to ship these sensitive/generated files:"
    $bad | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }
    throw "Sensitive/generated files are staged. Fix .gitignore or unstage them."
  }
}

Require-Command git
Require-Command gh
Assert-Not-UserProfileRoot

$profile = Read-JsonFile ".agy\GITHUB_PROFILE.json"

if (!$Repo -and $profile)       { $Repo = $profile.repo }
if (!$Mode -and $profile)       { $Mode = $profile.mode }
if (!$Visibility -and $profile) { $Visibility = $profile.visibility }
if (!$Branch -and $profile)     { $Branch = $profile.branch }
if (!$Message -and $profile)    { $Message = $profile.default_commit_message }

if (!$Repo)       { throw "Repo is required. Pass -Repo owner/name or set .agy/GITHUB_PROFILE.json" }
if (!$Mode)       { $Mode = "direct" }
if (!$Visibility) { $Visibility = "private" }
if (!$Branch)     { $Branch = "main" }
if (!$Message)    { $Message = "ship: update project $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }

gh auth status | Out-Host

if (!(Test-Path ".git")) {
  git init -b $Branch
} else {
  git branch -M $Branch
}

git config core.autocrlf false

if (!$SkipChecks) {
  if (Test-Path ".agents\hooks\Test-HookContract.ps1") {
    powershell -NoProfile -ExecutionPolicy Bypass -File ".agents\hooks\Test-HookContract.ps1"
  }

  if (Test-Path "scripts\windows\Test-EnvironmentContract.ps1") {
    powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\windows\Test-EnvironmentContract.ps1"
  }

  Run-NpmScriptIfExists "typecheck"
  Run-NpmScriptIfExists "test"
  Run-NpmScriptIfExists "build"
  Run-NpmScriptIfExists "test:semantic"
}

if ($Mode -eq "pr") {
  $shipBranch = "ship/" + (Get-Date -Format "yyyyMMdd-HHmmss")
  git checkout -B $shipBranch
}

git add -A
Assert-NoDangerousStagedFiles

$status = git status --short
if (!$status) {
  Write-Host "No changes to ship."
  exit 0
}

git status --short
git commit -m $Message

$repoExists = $false
gh repo view $Repo *> $null
if ($LASTEXITCODE -eq 0) { $repoExists = $true }

$hasOrigin = $false
git remote get-url origin *> $null
if ($LASTEXITCODE -eq 0) { $hasOrigin = $true }

if (!$repoExists -and !$hasOrigin) {
  if ($Mode -eq "pr") {
    throw "PR mode cannot be used for the first publish. Run direct mode once first."
  }

  $visibilityFlag = "--$Visibility"
  gh repo create $Repo $visibilityFlag --source=. --remote=origin --push
}
elseif ($Mode -eq "direct") {
  if (!$hasOrigin) {
    git remote add origin "https://github.com/$Repo.git"
  }

  git push -u origin $Branch
}
elseif ($Mode -eq "pr") {
  if (!$hasOrigin) {
    git remote add origin "https://github.com/$Repo.git"
  }

  git push -u origin HEAD

  gh pr create `
    --base $Branch `
    --head $shipBranch `
    --title $Message `
    --body "Automated project update from Antigravity pipeline."
}

Write-Host ""
Write-Host "GitHub sync complete."
Write-Host "Repo: https://github.com/$Repo"

gh repo view $Repo --web=false

try {
  gh run list --repo $Repo --limit 5
} catch {
  Write-Host "No GitHub Actions runs visible or Actions not configured."
}
