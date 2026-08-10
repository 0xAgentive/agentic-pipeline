[CmdletBinding()]
param([string]$RepoRoot='.',[string]$OutputRoot='',[switch]$Force)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $Root 'scripts\windows\common\NativeProcess.ps1')
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path $Root '.artifacts\release-kit\1.2.19\action-bridge'}
$Output=[IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Force $Output|Out-Null
$Zip=Join-Path $Output 'agentic-action-bridge-1.2.19.zip'
if((Test-Path -LiteralPath $Zip)-and-not$Force){throw "Output exists: $Zip"}
$CommitResult=Invoke-AgenticNativeProcess -FilePath 'git' -ArgumentList @('-C',$Root,'rev-parse','HEAD')
Assert-AgenticNativeSuccess -Result $CommitResult -Description 'git rev-parse'
$Commit=$CommitResult.StdOut.Trim()
if($Commit-notmatch'^[0-9a-fA-F]{40}$'){throw 'Invalid source commit.'}
$Stage=Join-Path ([IO.Path]::GetTempPath()) ('action-bridge-1.2.19-'+[guid]::NewGuid().ToString('N'))
$Pack=Join-Path $Stage 'agentic-action-bridge-1.2.19'
New-Item -ItemType Directory -Force $Pack|Out-Null
$Utf8=[Text.UTF8Encoding]::new($false)
try{
  foreach($Name in @('companion_action_bridge.py','Install-CompanionActionBridge.ps1','Run-CompanionActionBridgeWorker.ps1','Import-CompanionActionPacket.ps1','Uninstall-CompanionActionBridge.ps1')){Copy-Item -LiteralPath (Join-Path $Root ('scripts\bridge\'+$Name)) -Destination (Join-Path $Pack $Name) -Force}
  $Version=[ordered]@{schema_version='1.0.0';ecosystem_version='1.2.19';component='action_bridge';version='1.2.19';source_commit=$Commit;primary_packet_extension='.json';external_packet_authorization='local_capability_injection'}
  [IO.File]::WriteAllText((Join-Path $Pack 'VERSION.json'),($Version|ConvertTo-Json -Depth 10),$Utf8)
  $Files=@(Get-ChildItem -LiteralPath $Pack -File|Sort-Object Name|ForEach-Object{[ordered]@{path=$_.Name;size_bytes=[int64]$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
  $Manifest=[ordered]@{schema_version='1.0.0';ecosystem_version='1.2.19';component='action_bridge';source_commit=$Commit;files=$Files}
  [IO.File]::WriteAllText((Join-Path $Pack 'MANIFEST.json'),($Manifest|ConvertTo-Json -Depth 10),$Utf8)
  Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $Pack '*') -DestinationPath $Zip -CompressionLevel Optimal
  Write-Host "Action Bridge built: $Zip"
}finally{Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue}
