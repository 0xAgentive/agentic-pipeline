[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$KitRoot = $PSScriptRoot,
  [switch]$SkipPull,
  [switch]$ForceReapply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ExpectedOrigin = 'https://github.com/0xAgentive/agentic-pipeline'
$OverlayRoot = Join-Path $KitRoot 'payload\repo-overlay'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or newer is required.' }
foreach ($Command in @('git','node')) {
  if (!(Get-Command $Command -ErrorAction SilentlyContinue)) { throw "$Command is required." }
}
if (!(Test-Path -LiteralPath $OverlayRoot -PathType Container)) { throw "Repository overlay not found: $OverlayRoot" }

$TransportLibraryCandidates = @(
  (Join-Path $KitRoot 'lib\GitHubTransport.ps1'),
  (Join-Path $PSScriptRoot 'GitHubTransport.ps1')
)
$TransportLibrary = $TransportLibraryCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$TransportLibrary) { throw 'GitHub transport helper was not found.' }
. $TransportLibrary

$KitVerifier = Join-Path $KitRoot 'Verify-AgenticPipeline-v1.2.25-Kit.ps1'
if (Test-Path -LiteralPath $KitVerifier -PathType Leaf) {
  & $KitVerifier -KitRoot $KitRoot
}

function Invoke-Native {
  param([string]$FilePath,[string[]]$ArgumentList,[switch]$AllowFailure,[string]$WorkingDirectory='')
  return Invoke-TransportNative -FilePath $FilePath -ArgumentList $ArgumentList -AllowFailure:$AllowFailure -WorkingDirectory $WorkingDirectory
}
function Write-Json([string]$Path,[object]$Value) {
  New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),$Utf8NoBom)
}

$PwshExe = (Get-Command pwsh -ErrorAction Stop).Source

function Invoke-RepositoryScript {
  param(
    [Parameter(Mandatory=$true)][string]$RepositoryRoot,
    [Parameter(Mandatory=$true)][string]$RelativePath,
    [string[]]$ArgumentList = @(),
    [string]$DisplayName = ''
  )
  $ScriptPath = Join-Path $RepositoryRoot $RelativePath
  if (!(Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Required repository script is missing: $RelativePath"
  }
  $Name = if ([string]::IsNullOrWhiteSpace($DisplayName)) { $RelativePath } else { $DisplayName }
  Write-Host "[$Name]"
  $Result = Invoke-Native -FilePath $PwshExe -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath) + @($ArgumentList)) -WorkingDirectory $RepositoryRoot
  $Result.Lines | ForEach-Object { Write-Host $_ }
  return $Result
}

function Copy-OverlayToRepository {
  param([Parameter(Mandatory=$true)][string]$RepositoryRoot)
  $OverlayApplyScript = Join-Path $OverlayRoot 'scripts\release\Apply-CandidateOverlay.ps1'
  if (-not (Test-Path -LiteralPath $OverlayApplyScript -PathType Leaf)) { throw "Attribute-aware overlay helper is missing: $OverlayApplyScript" }
  [string[]]$ExpectedPaths = @(Get-ChildItem -LiteralPath $OverlayRoot -Recurse -File | ForEach-Object {
    [IO.Path]::GetRelativePath($OverlayRoot,$_.FullName).Replace('\','/')
  } | Sort-Object -Unique)
  if ($ExpectedPaths.Count -eq 0) {
    Write-Host 'Overlay has no expected paths; candidate bytes remain untouched.'
    return
  }
  & $OverlayApplyScript -CandidateRoot $RepositoryRoot -PayloadRoot $OverlayRoot -ExpectedPaths $ExpectedPaths -Apply | Out-Host
}

function Test-RepositoryTree {
  param([Parameter(Mandatory=$true)][string]$RepositoryRoot)

  Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Filter '*.ps1' | Where-Object { (($_.FullName -replace '\\','/')) -notmatch '/\.git/|/\.artifacts/' } | ForEach-Object {
    $Tokens=$null;$Errors=$null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$Tokens,[ref]$Errors) | Out-Null
    if ($Errors.Count) { throw "PowerShell parse error: $($_.FullName): $($Errors[0].Message)" }
  }
  Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Filter '*.json' | Where-Object { (($_.FullName -replace '\\','/')) -notmatch '/\.git/|/\.artifacts/|/docs/archive/' } | ForEach-Object {
    try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null }
    catch { throw "Invalid JSON: $($_.FullName): $($_.Exception.Message)" }
  }
  Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Filter '*.cjs' | Where-Object { (($_.FullName -replace '\\','/')) -notmatch '/\.git/|/\.artifacts/' } | ForEach-Object {
    Invoke-Native -FilePath node -ArgumentList @('--check',$_.FullName) | Out-Null
  }

  Invoke-Native -FilePath git -ArgumentList @('-C',$RepositoryRoot,'diff','--check') | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $RepositoryRoot -RelativePath 'scripts\windows\Test-HumanDocsCleanup.ps1' -ArgumentList @() -DisplayName 'human docs validation' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $RepositoryRoot -RelativePath 'scripts\windows\Validate-AgenticPipelinePackage.ps1' -ArgumentList @('-RepoRoot',$RepositoryRoot,'-Strict') -DisplayName 'hard package validation' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $RepositoryRoot -RelativePath 'scripts\windows\Test-RuntimeTruth.ps1' -ArgumentList @('-RepoRoot',$RepositoryRoot,'-StrictHotPath') -DisplayName 'runtime truth validation' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $RepositoryRoot -RelativePath 'scripts\windows\Test-DistributionIntegrity.ps1' -ArgumentList @('-RepoRoot',$RepositoryRoot) -DisplayName 'distribution integrity' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $RepositoryRoot -RelativePath 'scripts\windows\companion\Test-AutonomousConvergenceContracts.ps1' -ArgumentList @('-RepoRoot',$RepositoryRoot) -DisplayName 'autonomous convergence contracts' | Out-Null
}

function Test-ZipArtifactSafety {
  param(
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [Parameter(Mandatory=$true)][string]$Label
  )
  if (!(Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "$Label was not built: $ArchivePath" }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    if ($Archive.Entries.Count -lt 1) { throw "$Label is empty: $ArchivePath" }
    $Unsafe = @($Archive.Entries | Where-Object {
      $_.FullName -match '(^|/)\.\.(/|$)' -or
      $_.FullName -match '^[A-Za-z]:' -or
      $_.FullName.StartsWith('/') -or
      $_.FullName.StartsWith('\')
    })
    if ($Unsafe.Count -gt 0) { throw "$Label contains unsafe archive paths: $ArchivePath" }
  }
  finally { $Archive.Dispose() }
}

$GhCommand = Get-Command gh -ErrorAction SilentlyContinue
if ($GhCommand) {
  try { Initialize-GitHubCredentialHelper | Out-Null }
  catch { Write-Warning "GitHub CLI credential-helper setup was not completed for the local-only phase: $($_.Exception.Message)" }
}

if (!(Test-Path -LiteralPath $RepoRoot -PathType Container)) {
  $Parent = Split-Path -Parent $RepoRoot
  New-Item -ItemType Directory -Force $Parent | Out-Null
  Invoke-GitHubGit -WorkingDirectory $Parent -GitArguments @('clone',($ExpectedOrigin + '.git'),$RepoRoot) -OperationName 'Clone Agentic Pipeline repository' | Out-Null
}

$Repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$Origin=(Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'remote','get-url','origin')).Text.Trim()
if ((Normalize-GitHubOrigin $Origin) -ne (Normalize-GitHubOrigin $ExpectedOrigin)) { throw "Unexpected Git origin: $Origin" }

$Status=(Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'status','--porcelain=v1','--untracked-files=all')).Lines
if ($Status.Count -gt 0) {
  Write-Host 'Repository is dirty:'
  $Status | ForEach-Object { Write-Host $_ }
  throw 'Refusing to update a dirty Pipeline repository.'
}

Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'checkout','main') | Out-Null
$NetworkProfiles = New-Object System.Collections.Generic.List[string]
if (!$SkipPull) {
  $Fetch = Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('fetch','origin','--tags','--prune') -OperationName 'Fetch origin'
  $NetworkProfiles.Add([string]$Fetch.TransportProfile) | Out-Null
  $Pull = Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('pull','--ff-only','origin','main') -OperationName 'Fast-forward local main'
  $NetworkProfiles.Add([string]$Pull.TransportProfile) | Out-Null
}

$InitialHead=(Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'rev-parse','HEAD')).Text.Trim()
$VersionPath=Join-Path $Repo 'VERSION.json'
if (!(Test-Path -LiteralPath $VersionPath)) { throw 'VERSION.json is missing from local repository.' }
$BeforeVersion=Get-Content -LiteralPath $VersionPath -Raw | ConvertFrom-Json
if ([string]($BeforeVersion.package_version) -notin @('1.2.6','1.2.9','1.2.10','1.2.11','1.2.12','1.2.13','1.2.14','1.2.15','1.2.16','1.2.17','1.2.18','1.2.19','1.2.20','1.2.21','1.2.22','1.2.23','1.2.25')) { throw "Unsupported baseline package: $($BeforeVersion.package_version)" }

# Validate the exact overlay in an isolated detached worktree before touching local main.
if ([string]($BeforeVersion.package_version) -in @('1.2.6', '1.2.9', '1.2.10', '1.2.11', '1.2.12', '1.2.13', '1.2.14', '1.2.15', '1.2.16', '1.2.17', '1.2.18', '1.2.19', '1.2.20', '1.2.21', '1.2.22', '1.2.23') -or $ForceReapply) {
  $CandidateRoot = Join-Path $env:TEMP ('agentic-pipeline-1.2.25-candidate-' + [guid]::NewGuid().ToString('N'))
  $CandidateAdded = $false
  try {
    Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'worktree','add','--detach',$CandidateRoot,$InitialHead) | Out-Null
    $CandidateAdded = $true
    Copy-OverlayToRepository -RepositoryRoot $CandidateRoot
    Test-RepositoryTree -RepositoryRoot $CandidateRoot

    # Commit only inside the detached validation worktree so release builders
    # exercise the exact tracked candidate before local main is touched.
    Invoke-Native -FilePath git -ArgumentList @('-C',$CandidateRoot,'add','--all') | Out-Null
    $CandidateChanges = (Invoke-Native -FilePath git -ArgumentList @('-C',$CandidateRoot,'status','--porcelain=v1','--untracked-files=all')).Lines
    if ($CandidateChanges.Count -lt 1) { throw 'The isolated 1.2.25 candidate contains no overlay changes.' }
    Invoke-Native -FilePath git -ArgumentList @(
      '-C',$CandidateRoot,
      '-c','user.name=Agentic Pipeline Candidate Validator',
      '-c','user.email=candidate-validator@local.invalid',
      '-c','commit.gpgsign=false',
      'commit','-m','validation: isolated Agentic Pipeline 1.2.25 candidate'
    ) | Out-Null

    $CandidateArtifactRoot = Join-Path $env:TEMP ('agentic-pipeline-1.2.25-release-preflight-' + [guid]::NewGuid().ToString('N'))
    try {
      Invoke-RepositoryScript -RepositoryRoot $CandidateRoot -RelativePath 'scripts\windows\Build-ReleasePackage.ps1' -ArgumentList @('-RepoRoot',$CandidateRoot,'-Version','1.2.25','-OutputRoot',(Join-Path $CandidateArtifactRoot 'pipeline'),'-Force') -DisplayName 'isolated build Pipeline release package' | Out-Null
      Invoke-RepositoryScript -RepositoryRoot $CandidateRoot -RelativePath 'scripts\windows\companion\Build-CompanionPack-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$CandidateRoot,'-OutputRoot',(Join-Path $CandidateArtifactRoot 'companion'),'-Force') -DisplayName 'isolated build Companion pack' | Out-Null
      Invoke-RepositoryScript -RepositoryRoot $CandidateRoot -RelativePath 'scripts\windows\Build-AgenticProjectRuntimeOverlay-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$CandidateRoot,'-OutputRoot',(Join-Path $CandidateArtifactRoot 'runtime'),'-Force') -DisplayName 'isolated build Antigravity runtime overlay' | Out-Null
      Invoke-RepositoryScript -RepositoryRoot $CandidateRoot -RelativePath 'scripts\bridge\Build-CompanionActionBridgePackage-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$CandidateRoot,'-OutputRoot',(Join-Path $CandidateArtifactRoot 'action-bridge'),'-Force') -DisplayName 'isolated build Action Bridge package' | Out-Null
      Invoke-RepositoryScript -RepositoryRoot $CandidateRoot -RelativePath 'integrations\companion-handoff-1.2.25\Build-AgenticContextHandoffPackage-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$CandidateRoot,'-OutputRoot',(Join-Path $CandidateArtifactRoot 'handoff-compatibility'),'-Force') -DisplayName 'isolated build Context Handoff package' | Out-Null

      Test-ZipArtifactSafety -ArchivePath (Join-Path $CandidateArtifactRoot 'pipeline\agentic-pipeline-1.2.25.zip') -Label 'Isolated Pipeline release ZIP'
      Test-ZipArtifactSafety -ArchivePath (Join-Path $CandidateArtifactRoot 'companion\agentic-companion-1.2.25.zip') -Label 'Isolated Companion ZIP'
      Test-ZipArtifactSafety -ArchivePath (Join-Path $CandidateArtifactRoot 'runtime\agentic-project-runtime-1.2.25.zip') -Label 'Isolated runtime overlay ZIP'
      Test-ZipArtifactSafety -ArchivePath (Join-Path $CandidateArtifactRoot 'action-bridge\agentic-action-bridge-1.2.25.zip') -Label 'Isolated Action Bridge ZIP'
      Test-ZipArtifactSafety -ArchivePath (Join-Path $CandidateArtifactRoot 'handoff-compatibility\agentic-context-handoff-1.2.25.zip') -Label 'Isolated Handoff compatibility ZIP'
      Write-Host 'ISOLATED RELEASE PACKAGE BUILD PASSED.' -ForegroundColor Green
    }
    finally {
      Remove-Item -LiteralPath $CandidateArtifactRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'ISOLATED 1.2.25 CANDIDATE VALIDATION PASSED.' -ForegroundColor Green
  }
  finally {
    if ($CandidateAdded) {
      Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'worktree','remove','--force',$CandidateRoot) -AllowFailure | Out-Null
    }
    Remove-Item -LiteralPath $CandidateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'worktree','prune') -AllowFailure | Out-Null
  }
}

$MutationStarted=$false
$BackupBranch=$null
$ArtifactRoot=Join-Path $Repo '.artifacts\release-kit\1.2.25'
try {
  if ([string]($BeforeVersion.package_version) -eq '1.2.25' -and !$ForceReapply) {
    Write-Host 'Local repository already declares 1.2.25. Running validation and package build only.'
  }
  else {
    $BackupBranch="backup/pre-v1.2.25-$Stamp"
    Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'branch',$BackupBranch) | Out-Null
    Write-Host "Backup branch created: $BackupBranch"
    $MutationStarted=$true

    Copy-OverlayToRepository -RepositoryRoot $Repo
  }

  Test-RepositoryTree -RepositoryRoot $Repo

  $Changes=(Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'status','--porcelain=v1','--untracked-files=all')).Lines
  if ($Changes.Count -gt 0) {
    Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'add','--all') | Out-Null
    Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'commit','-m','release: Agentic Pipeline 1.2.25 source-immutable finalization') | Out-Null
  }

  $Version=Get-Content -LiteralPath $VersionPath -Raw | ConvertFrom-Json
  if ([string]($Version.package_version) -ne '1.2.25' -or [string]($Version.runtime_version) -ne '1.2.25' -or [string]($Version.companion_version) -ne '1.2.25') {
    throw 'Version matrix is not 1.2.25 / 1.2.25 / 1.2.25 after update.'
  }
  $FinalStatus=(Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'status','--porcelain=v1','--untracked-files=all')).Lines
  if ($FinalStatus.Count -gt 0) { throw 'Repository is not clean after commit.' }
  $Head=(Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'rev-parse','HEAD')).Text.Trim()

  Remove-Item -LiteralPath $ArtifactRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $ArtifactRoot | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $Repo -RelativePath 'scripts\windows\Build-ReleasePackage.ps1' -ArgumentList @('-RepoRoot',$Repo,'-Version','1.2.25','-OutputRoot',(Join-Path $ArtifactRoot 'pipeline'),'-Force') -DisplayName 'build Pipeline release package' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $Repo -RelativePath 'scripts\windows\companion\Build-CompanionPack-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$Repo,'-OutputRoot',(Join-Path $ArtifactRoot 'companion'),'-Force') -DisplayName 'build Companion pack' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $Repo -RelativePath 'scripts\windows\Build-AgenticProjectRuntimeOverlay-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$Repo,'-OutputRoot',(Join-Path $ArtifactRoot 'runtime'),'-Force') -DisplayName 'build Antigravity runtime overlay' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $Repo -RelativePath 'scripts\bridge\Build-CompanionActionBridgePackage-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$Repo,'-OutputRoot',(Join-Path $ArtifactRoot 'action-bridge'),'-Force') -DisplayName 'build Action Bridge package' | Out-Null
  Invoke-RepositoryScript -RepositoryRoot $Repo -RelativePath 'integrations\companion-handoff-1.2.25\Build-AgenticContextHandoffPackage-v1.2.25.ps1' -ArgumentList @('-RepoRoot',$Repo,'-OutputRoot',(Join-Path $ArtifactRoot 'handoff-compatibility'),'-Force') -DisplayName 'build Context Handoff package' | Out-Null

  $Result=[ordered]@{
    schema_version='1.2.9';status='PASS';operation='local_upgrade';repo_root=$Repo;origin=$Origin;branch='main';head=$Head
    initial_head=$InitialHead;package_version='1.2.25';runtime_version='1.2.25';companion_version='1.2.25';artifact_root=$ArtifactRoot
    network_transport_profiles=@($NetworkProfiles | Select-Object -Unique)
    release_zip=(Join-Path $ArtifactRoot 'pipeline\agentic-pipeline-1.2.25.zip')
    companion_zip=(Join-Path $ArtifactRoot 'companion\agentic-companion-1.2.25.zip')
    runtime_overlay_zip=(Join-Path $ArtifactRoot 'runtime\agentic-project-runtime-1.2.25.zip')
    action_bridge_zip=(Join-Path $ArtifactRoot 'action-bridge\agentic-action-bridge-1.2.25.zip')
    handoff_compatibility_zip=(Join-Path $ArtifactRoot 'handoff-compatibility\agentic-context-handoff-1.2.25.zip')
    completed_at_utc=(Get-Date).ToUniversalTime().ToString('o')
  }
  $ResultPath=Join-Path $ArtifactRoot 'LOCAL_UPGRADE_RESULT.json'
  Write-Json $ResultPath $Result

  Write-Host 'LOCAL AGENTIC PIPELINE 1.2.25 UPGRADE COMPLETED.' -ForegroundColor Green
  Write-Host "Repository: $Repo"
  Write-Host "HEAD: $Head"
  Write-Host "Artifacts: $ArtifactRoot"
  if ($NetworkProfiles.Count -gt 0) {
    $ProfileSummary = (@($NetworkProfiles | Select-Object -Unique) -join ", ")
    Write-Host "GitHub transport: $ProfileSummary"
  }
}
catch {
  if ($MutationStarted) {
    $FailureHead = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'rev-parse','HEAD') -AllowFailure).Text.Trim()
    $FailureStatus = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'status','--porcelain=v2','-z','--untracked-files=all') -AllowFailure).Text
    $FailureReceipt = [ordered]@{
      schema_version='1.0.0';status='BLOCKED';operation='local_upgrade';initial_head=$InitialHead;failure_head=$FailureHead
      backup_branch=$BackupBranch;working_tree_dirty=($FailureStatus.Length -gt 0);error=$_.Exception.Message
      recovery_policy='preserve_state_and_backup_branch_for_review';failed_at_utc=(Get-Date).ToUniversalTime().ToString('o')
    }
    New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null
    Write-Json (Join-Path $ArtifactRoot 'LOCAL_UPGRADE_FAILURE.json') $FailureReceipt
    Write-Warning "The local upgrade stopped after mutation. State was preserved without reset/clean; backup branch retained: $BackupBranch"
  }
  throw
}
