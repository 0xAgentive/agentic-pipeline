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
Set-StrictMode -Version 2.0

function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
  )
  & $Exe @Arguments
  $code = $LASTEXITCODE
  if ($null -ne $code -and $code -ne 0) { throw "Native command failed with exit code ${code}: $Exe $($Arguments -join ' ')" }
}
function Require-Command { param([string]$Name) if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required command not found: $Name" } }
function Read-JsonFile { param([string]$Path) if (Test-Path $Path) { return (Get-Content $Path -Raw | ConvertFrom-Json) } return $null }
function Assert-Not-UserProfileRoot { $cwd=(Resolve-Path ".").Path; $UserProfileRoot=(Resolve-Path $env:USERPROFILE).Path; if ($cwd -eq $UserProfileRoot) { throw "Refusing to publish from user profile root: $cwd" } }
function Run-NpmScriptIfExists { param([string]$Name) if (!(Test-Path "package.json")) { return }; $pkg=Get-Content "package.json" -Raw | ConvertFrom-Json; if ($pkg.scripts -and ($pkg.scripts.PSObject.Properties.Name -contains $Name)) { Invoke-NativeChecked npm run $Name } }
function Assert-NoDangerousStagedFiles {
  $staged = & git diff --cached --name-only
  if ($LASTEXITCODE -ne 0) { throw "git diff --cached failed" }
  $denyPatterns = @('(^|/)\.env($|\.)','\.pem$','\.key$','\.pfx$','\.p12$','\.sqlite$','\.db$','(^|/)node_modules/','(^|/)dist/','(^|/)build/','(^|/)\.agy/','(^|/)\.codebase-memory/','\.log$','\.zip$','\.har$','\.trace$','\.bak-')
  $bad=@()
  foreach ($file in $staged) {
    if ($file -eq ".agy/GITHUB_PROFILE.json" -or $file -eq ".agy\GITHUB_PROFILE.json") { continue }
    foreach ($pattern in $denyPatterns) { if ($file -match $pattern) { $bad += $file; break } }
  }
  if ($bad.Count -gt 0) { Write-Host "Refusing to ship these sensitive/generated files:"; $bad | Sort-Object -Unique | ForEach-Object { Write-Host "- $_" }; throw "Sensitive/generated files are staged." }
}
function Append-MachineEvidence {
  param([string]$Repo, [string]$Branch, [string]$Message)
  $path = ".agy/EVIDENCE_LOG.md"
  if (!(Test-Path $path)) { return }
  $commit = (& git rev-parse --short HEAD).Trim()
  $utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $entry = @"
## $utc - githubsync machine evidence

Command: scripts/github/Sync-GitHub.ps1
Repo: $Repo
Branch: $Branch
Commit: $commit
Message: $Message
Result: push/verification command completed with exit code 0

"@
  Add-Content $path $entry -Encoding UTF8
}

Require-Command git; Require-Command gh; Assert-Not-UserProfileRoot
$profile = Read-JsonFile ".agy/GITHUB_PROFILE.json"
if (!$Repo -and $profile) { $Repo = $profile.repo }
if (!$Mode -and $profile) { $Mode = $profile.mode }
if (!$Visibility -and $profile) { $Visibility = $profile.visibility }
if (!$Branch -and $profile) { $Branch = $profile.branch }
if (!$Message -and $profile) { $Message = $profile.default_commit_message }
if (!$Repo) { throw "Repo is required." }
if (!$Mode) { $Mode = "direct" }
if (!$Visibility) { $Visibility = "private" }
if (!$Branch) { $Branch = "main" }
if (!$Message) { $Message = "ship: update project $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
Invoke-NativeChecked gh auth status
if (!(Test-Path ".git")) { Invoke-NativeChecked git init -b $Branch } else { Invoke-NativeChecked git branch -M $Branch }
Invoke-NativeChecked git config core.autocrlf false
if (!$SkipChecks) {
  if (Test-Path ".agents/hooks/Test-HookContract.ps1") { Invoke-NativeChecked powershell -NoProfile -ExecutionPolicy Bypass -File ".agents/hooks/Test-HookContract.ps1" }
  if (Test-Path "scripts/windows/Test-EnvironmentContract.ps1") { Invoke-NativeChecked powershell -NoProfile -ExecutionPolicy Bypass -File "scripts/windows/Test-EnvironmentContract.ps1" }
  Run-NpmScriptIfExists "typecheck"; Run-NpmScriptIfExists "test"; Run-NpmScriptIfExists "build"; Run-NpmScriptIfExists "test:semantic"
}
if ($Mode -eq "pr") { $shipBranch = "ship/" + (Get-Date -Format "yyyyMMdd-HHmmss"); Invoke-NativeChecked git checkout -B $shipBranch }
Invoke-NativeChecked git add -A
Assert-NoDangerousStagedFiles
$status = & git status --short
if (!$status) { Write-Host "No changes to ship."; exit 0 }
$status | Out-Host
Invoke-NativeChecked git commit -m $Message
$repoExists = $false; & gh repo view $Repo *> $null; if ($LASTEXITCODE -eq 0) { $repoExists = $true }
$hasOrigin = $false; & git remote get-url origin *> $null; if ($LASTEXITCODE -eq 0) { $hasOrigin = $true }
if (!$repoExists -and !$hasOrigin) { if ($Mode -eq "pr") { throw "PR mode cannot be used for first publish." }; $visibilityFlag = "--$Visibility"; Invoke-NativeChecked gh repo create $Repo $visibilityFlag --source=. --remote=origin --push }
elseif ($Mode -eq "direct") { if (!$hasOrigin) { Invoke-NativeChecked git remote add origin "https://github.com/$Repo.git" }; Invoke-NativeChecked git push -u origin $Branch }
elseif ($Mode -eq "pr") { if (!$hasOrigin) { Invoke-NativeChecked git remote add origin "https://github.com/$Repo.git" }; Invoke-NativeChecked git push -u origin HEAD; Invoke-NativeChecked gh pr create --base $Branch --head $shipBranch --title $Message --body "Automated project update from Antigravity pipeline." }
Append-MachineEvidence -Repo $Repo -Branch $Branch -Message $Message
Write-Host "GitHub sync complete. Repo: https://github.com/$Repo"
Invoke-NativeChecked gh repo view $Repo --web=false
try { Invoke-NativeChecked gh run list --repo $Repo --limit 5 } catch { Write-Host "No GitHub Actions runs visible or Actions not configured." }
