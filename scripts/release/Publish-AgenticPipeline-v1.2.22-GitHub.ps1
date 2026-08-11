[CmdletBinding()]
param(
  [string]$RepoRoot = "$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$ArtifactRoot = "",
  [switch]$ForceUpload
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ExpectedOrigin = 'https://github.com/0xAgentive/agentic-pipeline'
$Repo = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  $ArtifactRoot = Join-Path $Repo '.artifacts\release-kit\1.2.22'
}

$TransportLibraryCandidates = @(
  (Join-Path $PSScriptRoot 'lib\GitHubTransport.ps1'),
  (Join-Path $PSScriptRoot 'GitHubTransport.ps1')
)
$TransportLibrary = $TransportLibraryCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (!$TransportLibrary) { throw 'GitHub transport helper was not found.' }
. $TransportLibrary

$Gh = Initialize-GitHubCredentialHelper

function Invoke-Native {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$AllowFailure,
    [string]$WorkingDirectory = ''
  )
  return Invoke-TransportNative -FilePath $FilePath -ArgumentList $ArgumentList -AllowFailure:$AllowFailure -WorkingDirectory $WorkingDirectory
}

$Origin = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'remote','get-url','origin')).Text.Trim()
if ((Normalize-GitHubOrigin $Origin) -ne (Normalize-GitHubOrigin $ExpectedOrigin)) { throw "Unexpected origin: $Origin" }
$Branch = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'branch','--show-current')).Text.Trim()
if ($Branch -ne 'main') { throw "Publish requires main branch. Current: $Branch" }
$Dirty = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'status','--porcelain=v1','--untracked-files=all')).Lines
if ($Dirty.Count -gt 0) { throw 'Repository must be clean before GitHub publication.' }
$Version = Get-Content -LiteralPath (Join-Path $Repo 'VERSION.json') -Raw | ConvertFrom-Json
if ([string]($Version.package_version) -ne '1.2.22') { throw 'Local repository is not version 1.2.22.' }
$ReleaseTitle = "Agentic Pipeline 1.2.22 - $([string]$Version.release_name)"

$Head = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'rev-parse','HEAD')).Text.Trim()
$Fetch = Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('fetch','origin','--tags','--prune') -OperationName 'Fetch origin before publication'

$RemoteMainLine = (Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('ls-remote','--heads','origin','refs/heads/main') -OperationName 'Read remote main').Text.Trim()
if ([string]::IsNullOrWhiteSpace($RemoteMainLine)) { throw 'Remote main branch could not be resolved.' }
$RemoteMain = ($RemoteMainLine -split '\s+')[0]
$Ancestor = Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'merge-base','--is-ancestor',$RemoteMain,$Head) -AllowFailure
if ($Ancestor.Code -ne 0) {
  throw "Remote main ($RemoteMain) is not an ancestor of local HEAD ($Head). Publication stopped to avoid a non-fast-forward update."
}

$PushMain = Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('push','origin','main') -OperationName 'Push main'
$RemoteMainAfter = ((Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('ls-remote','--heads','origin','refs/heads/main') -OperationName 'Verify remote main').Text.Trim() -split '\s+')[0]
if ($RemoteMainAfter -ne $Head) { throw "Remote main verification failed. Expected $Head, got $RemoteMainAfter" }

$Tag = 'v1.2.22'
$TagQuery = Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('ls-remote','--tags','origin',("refs/tags/$Tag"),("refs/tags/$Tag^{}")) -OperationName 'Read remote release tag'
$TagLines = @($TagQuery.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$RemoteTagCommit = $null
if ($TagLines.Count -gt 0) {
  $Peeled = $TagLines | Where-Object { [string]$_ -match '\^\{\}$' } | Select-Object -First 1
  $Direct = $TagLines | Where-Object { [string]$_ -notmatch '\^\{\}$' } | Select-Object -First 1
  $RemoteTagCommit = if ($Peeled) { (([string]$Peeled) -split '\s+')[0] } elseif ($Direct) { (([string]$Direct) -split '\s+')[0] } else { $null }
  if ($RemoteTagCommit -and $RemoteTagCommit -ne $Head) { throw "Remote tag $Tag already resolves to another commit: $RemoteTagCommit" }
}
else {
  $LocalTag = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'tag','--list',$Tag)).Text.Trim()
  if ($LocalTag) {
    $LocalTagCommit = (Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'rev-parse',("$Tag^{}"))).Text.Trim()
    if ($LocalTagCommit -ne $Head) { throw "Local tag $Tag already resolves to another commit: $LocalTagCommit" }
  }
  else {
    Invoke-Native -FilePath git -ArgumentList @('-C',$Repo,'tag','-a',$Tag,'-m',$ReleaseTitle) | Out-Null
  }
  Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('push','origin',$Tag) -OperationName "Push tag $Tag" | Out-Null
}

$RemoteTagVerify = Invoke-GitHubGit -WorkingDirectory $Repo -GitArguments @('ls-remote','--tags','origin',("refs/tags/$Tag^{}"),("refs/tags/$Tag")) -OperationName 'Verify remote release tag'
$RemoteTagLines = @($RemoteTagVerify.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$VerifyPeeled = $RemoteTagLines | Where-Object { [string]$_ -match '\^\{\}$' } | Select-Object -First 1
$VerifyDirect = $RemoteTagLines | Where-Object { [string]$_ -notmatch '\^\{\}$' } | Select-Object -First 1
$VerifiedTagCommit = if ($VerifyPeeled) { (([string]$VerifyPeeled) -split '\s+')[0] } elseif ($VerifyDirect) { (([string]$VerifyDirect) -split '\s+')[0] } else { $null }
if ($VerifiedTagCommit -ne $Head) { throw "Remote tag verification failed. Expected $Head, got $VerifiedTagCommit" }

$ReleaseZip = Join-Path $ArtifactRoot 'pipeline\agentic-pipeline-1.2.22.zip'
$CompanionZip = Join-Path $ArtifactRoot 'companion\agentic-companion-1.2.22.zip'
$RuntimeZip = Join-Path $ArtifactRoot 'runtime\agentic-project-runtime-1.2.22.zip'
$ActionBridgeZip = Join-Path $ArtifactRoot 'action-bridge\agentic-action-bridge-1.2.22.zip'
$HandoffCompatibilityZip = Join-Path $ArtifactRoot 'handoff-compatibility\agentic-context-handoff-1.2.22.zip'
$ReleaseArtifacts = @($ReleaseZip,$CompanionZip,$RuntimeZip,$ActionBridgeZip,$HandoffCompatibilityZip)
foreach ($Artifact in $ReleaseArtifacts) {
  if (!(Test-Path -LiteralPath $Artifact -PathType Leaf)) { throw "Release artifact missing: $Artifact" }
  if ((Get-Item -LiteralPath $Artifact).Length -le 0) { throw "Release artifact is empty: $Artifact" }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($Artifact in $ReleaseArtifacts) {
  $Archive = [System.IO.Compression.ZipFile]::OpenRead($Artifact)
  try {
    if ($Archive.Entries.Count -lt 1) { throw "Release ZIP contains no entries: $Artifact" }
  }
  finally { $Archive.Dispose() }
}

$Notes = Join-Path $ArtifactRoot 'RELEASE_NOTES_1.2.22.md'
$CanonicalNotes = Join-Path $Repo 'docs\maintainers\RELEASE_NOTES_1.2.22.md'
if (-not (Test-Path -LiteralPath $CanonicalNotes -PathType Leaf)) { throw "Canonical release notes are missing: $CanonicalNotes" }
Copy-Item -LiteralPath $CanonicalNotes -Destination $Notes -Force

$Existing = Invoke-Native -FilePath $Gh -ArgumentList @('release','view',$Tag,'--repo','0xAgentive/agentic-pipeline') -AllowFailure
if ($Existing.Code -ne 0) {
  Invoke-Native -FilePath $Gh -ArgumentList @(
    'release','create',$Tag,
    '--repo','0xAgentive/agentic-pipeline',
    '--title',$ReleaseTitle,
    '--notes-file',$Notes,
    $ReleaseZip,$CompanionZip,$RuntimeZip,$ActionBridgeZip,$HandoffCompatibilityZip
  ) | Out-Null
}
else {
  $UploadArguments = @('release','upload',$Tag,'--repo','0xAgentive/agentic-pipeline','--clobber',$ReleaseZip,$CompanionZip,$RuntimeZip,$ActionBridgeZip,$HandoffCompatibilityZip)
  Invoke-Native -FilePath $Gh -ArgumentList $UploadArguments | Out-Null
  Invoke-Native -FilePath $Gh -ArgumentList @(
    'release','edit',$Tag,
    '--repo','0xAgentive/agentic-pipeline',
    '--title',$ReleaseTitle,
    '--notes-file',$Notes
  ) | Out-Null
}

$ReleaseCheck = Invoke-Native -FilePath $Gh -ArgumentList @('release','view',$Tag,'--repo','0xAgentive/agentic-pipeline','--json','tagName,name,isDraft,isPrerelease')
$ReleaseData = $ReleaseCheck.Text | ConvertFrom-Json
if ([string]$ReleaseData.tagName -ne $Tag -or [bool]$ReleaseData.isDraft -or [bool]$ReleaseData.isPrerelease) { throw 'GitHub Release verification failed.' }

Write-Host 'GITHUB PUBLICATION COMPLETED.' -ForegroundColor Green
Write-Host 'Repository: 0xAgentive/agentic-pipeline'
Write-Host "Tag: $Tag"
Write-Host "HEAD: $Head"
Write-Host "Fetch transport: $($Fetch.TransportProfile)"
Write-Host "Push transport: $($PushMain.TransportProfile)"
