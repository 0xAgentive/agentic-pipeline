[CmdletBinding()]
param(
  [string]$RepoRoot="$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$ProjectId='',
  [string]$LogicalName='',
  [string]$HandoffRoot='C:\Scripts\AntigravityProjects\companion-handoff',
  [string]$DeploymentRoot='',
  [switch]$OpenFolder
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Repo=(Resolve-Path -LiteralPath $RepoRoot).Path
$Project=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Leaf=Split-Path -Leaf $Project
if([string]::IsNullOrWhiteSpace($LogicalName)){$LogicalName=$Leaf}
if([string]::IsNullOrWhiteSpace($ProjectId)){$ProjectId=($Leaf-replace'[^A-Za-z0-9._-]','-').Trim('-')}
if([string]::IsNullOrWhiteSpace($ProjectId)){throw 'ProjectId cannot be derived. Supply -ProjectId explicitly.'}
if([string]::IsNullOrWhiteSpace($DeploymentRoot)){$DeploymentRoot=Join-Path $env:USERPROFILE (Join-Path 'Documents\antigravity\companion-deployments' (Join-Path $ProjectId '1.2.9'))}
$Version=Get-Content -LiteralPath (Join-Path $Repo 'VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$Version.package_version-ne'1.2.9'-or[string]$Version.runtime_version-ne'1.2.9'-or[string]$Version.companion_version-ne'1.2.9'){throw 'Canonical repository is not Pipeline 1.2.9 / runtime 1.2.9 / Companion 1.2.9.'}
$RuntimeUpdater=Join-Path $Repo 'scripts\windows\Update-AgenticProjectRuntime-v1.2.9.ps1'
& $RuntimeUpdater -ProjectRoot $Project -RepoRoot $Repo -Apply -AllowDirty
if($LASTEXITCODE-ne0){throw 'Project runtime update failed.'}
$BridgeInstaller=Join-Path $Repo 'scripts\bridge\Install-CompanionActionBridge.ps1'
& $BridgeInstaller -ProjectId $ProjectId -ProjectRoot $Project -LogicalName $LogicalName -Apply
if($LASTEXITCODE-ne0){throw 'Companion Action Bridge installation failed.'}
$HandoffUpdater=Join-Path $Repo 'integrations\companion-handoff-1.2.9\Update-AgenticContextHandoff-v1.2.9.ps1'
& $HandoffUpdater -HandoffRoot $HandoffRoot -Apply
if($LASTEXITCODE-ne0){throw 'Companion Handoff compatibility update failed.'}
$CompanionZip=Join-Path $Repo '.artifacts\release-kit\1.2.9\companion\agentic-companion-1.2.9.zip'
if(-not(Test-Path -LiteralPath $CompanionZip -PathType Leaf)){& (Join-Path $Repo 'scripts\windows\companion\Build-CompanionPack-v1.2.9.ps1') -RepoRoot $Repo -OutputRoot (Split-Path -Parent $CompanionZip) -Force;if($LASTEXITCODE-ne0){throw 'Companion package build failed.'}}
$Stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
if(Test-Path -LiteralPath $DeploymentRoot -PathType Container){Move-Item -LiteralPath $DeploymentRoot -Destination ($DeploymentRoot+'.backup-'+$Stamp)}
New-Item -ItemType Directory -Force (Split-Path -Parent $DeploymentRoot)|Out-Null
Expand-Archive -LiteralPath $CompanionZip -DestinationPath $DeploymentRoot -Force
$PackSubdir=Get-ChildItem -LiteralPath $DeploymentRoot -Directory|Where-Object{$_.Name-like'agentic-companion-*'}|Select-Object -First 1
if($PackSubdir){Get-ChildItem -LiteralPath $PackSubdir.FullName -Force|ForEach-Object{Move-Item -LiteralPath $_.FullName -Destination $DeploymentRoot -Force};Remove-Item -LiteralPath $PackSubdir.FullName -Recurse -Force}
$Instructions = Join-Path $DeploymentRoot '01_PROJECT_INSTRUCTIONS_v1.2.9.md'
$Knowledge = Join-Path $DeploymentRoot 'knowledge'
$KnowledgeFiles = @(Get-ChildItem -LiteralPath $Knowledge -File -Filter '*.md')
if (-not (Test-Path -LiteralPath $Instructions -PathType Leaf) -or $KnowledgeFiles.Count -ne 16) {
  throw 'Prepared Companion deployment is incomplete.'
}
Set-Clipboard -Value (Get-Content -LiteralPath $Instructions -Raw -Encoding UTF8)
$BootstrapScript=Join-Path $Repo 'scripts\release\Create-Companion-Restart-Bootstrap-v1.2.9.ps1'
& $BootstrapScript -ProjectRoot $Project -PipelineRepo $Repo -OutputRoot $DeploymentRoot -HandoffRoot $HandoffRoot -LogicalName $LogicalName -ProjectId $ProjectId
if($LASTEXITCODE-ne0){throw 'Restart bootstrap creation failed.'}
$Bootstrap=Get-ChildItem -LiteralPath $DeploymentRoot -File -Filter 'COMPANION_RESTART_BOOTSTRAP_*.zip'|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
if(-not$Bootstrap){throw 'Restart bootstrap was not produced.'}
$FirstMessage='Проанализируй приложенный COMPANION_RESTART_BOOTSTRAP по COMPANION_ENTRY.md.'
[IO.File]::WriteAllText((Join-Path $DeploymentRoot 'NEW_CHAT_FIRST_MESSAGE.txt'),$FirstMessage,[Text.UTF8Encoding]::new($false))
$Checklist=@"
Companion 1.2.9 deployment is ready for project: $LogicalName

1. Replace the ChatGPT Project Instructions with 01_PROJECT_INSTRUCTIONS_v1.2.9.md (already copied to clipboard).
2. Replace Project Knowledge with one copy of every Markdown file in knowledge (00-15).
3. Retire the old Companion chat. Create a new chat in the same Project.
4. Upload $($Bootstrap.Name) and use NEW_CHAT_FIRST_MESSAGE.txt.
5. Downloaded AGENTIC_ACTION_PACKET_*.json files will be imported from Downloads by the local Action Bridge.
"@
[IO.File]::WriteAllText((Join-Path $DeploymentRoot 'CHATGPT_PROJECT_UPDATE_CHECKLIST.txt'),$Checklist,[Text.UTF8Encoding]::new($false))
$Result=[ordered]@{schema_version='1.2.9';status='PASS';project_id=$ProjectId;project=$LogicalName;project_root=$Project;pipeline_version='1.2.9';runtime_version='1.2.9';companion_version='1.2.9';deployment_root=$DeploymentRoot;bootstrap=$Bootstrap.FullName;generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText((Join-Path $DeploymentRoot 'DEPLOYMENT_RESULT.json'),($Result|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
Write-Host 'PROJECT RUNTIME / ACTION BRIDGE / HANDOFF / COMPANION DEPLOYMENT: PASS' -ForegroundColor Green
if($OpenFolder){Start-Process explorer.exe -ArgumentList "`"$DeploymentRoot`""}
