[CmdletBinding()]param([string]$RepoRoot='.')
Set-StrictMode -Version 3.0;$ErrorActionPreference='Stop';$Root=(Resolve-Path -LiteralPath $RepoRoot).Path;$Expected='1.2.21'
$E=Get-Content (Join-Path $Root 'ECOSYSTEM_VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$E.ecosystem_version-ne$Expected){throw 'ECOSYSTEM_VERSION mismatch.'}
foreach($Name in @('pipeline','runtime','playbook','companion','action_bridge','context_handoff')){if([string]$E.components.$Name-ne$Expected){throw "Component version mismatch: $Name"}}
$V=Get-Content (Join-Path $Root 'VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($Name in @('ecosystem_version','package_version','runtime_version','playbook_version','companion_version','action_bridge_version','context_handoff_version','handoff_compatibility')){if([string]$V.$Name-ne$Expected){throw "VERSION.json mismatch: $Name"}}
$C=Get-Content (Join-Path $Root 'docs\companion\VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
foreach($Name in @('ecosystem_version','companion_version','compatible_pipeline_package','compatible_runtime')){if([string]$C.$Name-ne$Expected){throw "Companion VERSION mismatch: $Name"}}
if([string]$C.action_packet_version-ne'1.2.9'){throw 'Companion Action Packet schema version mismatch.'}
foreach($Path in @('docs\companion\00_AGENTIC_PIPELINE_INDEX_v1.2.21.md','docs\companion\01_PROJECT_INSTRUCTIONS_v1.2.21.md','docs\companion\02_AGENT_TASK_PACK_CONTRACT_v1.2.21.md','docs\companion\SYSTEM_PROMPT_GPT56_COMPANION_v1.2.21.md','scripts\windows\companion\Build-CompanionPack-v1.2.21.ps1','scripts\windows\Build-AgenticProjectRuntimeOverlay-v1.2.21.ps1','scripts\bridge\Build-CompanionActionBridgePackage-v1.2.21.ps1','integrations\companion-handoff-1.2.21\Build-AgenticContextHandoffPackage-v1.2.21.ps1')){if(!(Test-Path (Join-Path $Root $Path)-PathType Leaf)){throw "Unified active file missing: $Path"}}
$ActiveRoots=@('docs\companion','scripts\release','scripts\bridge','integrations')
$StalePattern='(?i)(?:v|version[-_]?)(?:1\.2\.[0-9](?!\d)|4\.3\.5|1\.0\.0)|(?:pipeline|runtime|companion|action[-_ ]bridge|context[-_ ]handoff)[-_ ](?:1\.2\.[0-9](?!\d)|4\.3\.5|1\.0\.0)'
foreach($RelativeRoot in $ActiveRoots){
 $ActiveRoot=Join-Path $Root $RelativeRoot;if(!(Test-Path $ActiveRoot)){continue}
 foreach($File in Get-ChildItem -LiteralPath $ActiveRoot -Recurse -File -ErrorAction SilentlyContinue){
  if($File.FullName-match'[\\/]archive[\\/]'){continue}
  if($File.Name-match$StalePattern){throw "Stale active component version in filename: $($File.FullName)"}
 }
}
Write-Host 'Unified ecosystem version contract passed.'
