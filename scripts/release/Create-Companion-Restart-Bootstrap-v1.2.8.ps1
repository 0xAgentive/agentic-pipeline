[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ProjectRoot,
  [string]$PipelineRepo="$env:USERPROFILE\Documents\antigravity\agentic-pipeline",
  [string]$OutputRoot='',
  [string]$HandoffRoot='C:\Scripts\AntigravityProjects\companion-handoff',
  [string]$LogicalName='',
  [string]$ProjectId='',
  [int]$MaxTotalMB=120,
  [int]$MaxFileMB=5,
  [switch]$OpenFolder
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Utf8=[Text.UTF8Encoding]::new($false)
$Project=(Resolve-Path -LiteralPath $ProjectRoot).Path
$Pipeline=(Resolve-Path -LiteralPath $PipelineRepo).Path
$Leaf=Split-Path -Leaf $Project
if([string]::IsNullOrWhiteSpace($LogicalName)){$LogicalName=$Leaf}
if([string]::IsNullOrWhiteSpace($ProjectId)){$ProjectId=($Leaf-replace'[^A-Za-z0-9._-]','-').Trim('-')}
if([string]::IsNullOrWhiteSpace($ProjectId)){throw 'ProjectId cannot be derived. Supply -ProjectId explicitly.'}
if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path $env:USERPROFILE (Join-Path 'Documents\antigravity\companion-deployments' (Join-Path $ProjectId '1.2.8'))}
$Version=Get-Content -LiteralPath (Join-Path $Pipeline 'VERSION.json') -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$Version.package_version-ne'1.2.8'-or[string]$Version.runtime_version-ne'1.2.8'-or[string]$Version.companion_version-ne'1.2.8'){throw 'Restart bootstrap requires Pipeline 1.2.8 / runtime 1.2.8 / Companion 1.2.8.'}
$Stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$Stage=Join-Path $env:TEMP ('agentic-companion-restart-'+[guid]::NewGuid().ToString('N'))
$ZipPath=Join-Path $OutputRoot ("COMPANION_RESTART_BOOTSTRAP_${ProjectId}_$Stamp.zip")
$ResultPath=[IO.Path]::ChangeExtension($ZipPath,'.result.json')
$MaxTotal=[int64]$MaxTotalMB*1MB;$MaxFile=[int64]$MaxFileMB*1MB
$Total=[int64]0;$Included=@();$Excluded=@()
function Ensure-Dir([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Container)){New-Item -ItemType Directory -Force $Path|Out-Null}}
function Write-Utf8([string]$Path,[string]$Text){Ensure-Dir (Split-Path -Parent $Path);[IO.File]::WriteAllText($Path,$Text,$Utf8)}
function Is-Text([string]$Path){$Ext=[IO.Path]::GetExtension($Path).ToLowerInvariant();return $Ext-in@('.md','.txt','.json','.jsonl','.ndjson','.ts','.tsx','.js','.jsx','.cjs','.mjs','.py','.ps1','.psm1','.psd1','.yml','.yaml','.toml','.ini','.cfg','.xml','.html','.css','.scss','.sql','.sh','.cmd','.bat','.vbs','.lock')-or[IO.Path]::GetFileName($Path)-in@('package.json','tsconfig.json','vite.config.ts','.gitignore','.cbmignore','AGENTS.md','README')}
function Is-Excluded([string]$Path){$Normalized=($Path-replace'\\','/').ToLowerInvariant();return $Normalized-match'/(\.git|node_modules|dist|build|coverage|data|raw|logs?|\.artifacts|\.pipeline[^/]*|\.venv|venv|__pycache__|history|runs)/' -or $Normalized-match'\.(db|sqlite|sqlite3|db-wal|db-shm|zip|gz|7z|rar|png|jpg|jpeg|webp|pdf|exe|dll|bin|log|csv)$'}
function Add-TextFile([string]$Source,[string]$Relative,[string]$Category){if (-not (Test-Path -LiteralPath $Source -PathType Leaf)){return};$Item=Get-Item -LiteralPath $Source;if ((Is-Excluded $Source) -or -not (Is-Text $Source)){$script:Excluded+=,[ordered]@{source=$Source;reason='excluded_type_or_path'};return};if($Item.Length-gt$MaxFile){$script:Excluded+=,[ordered]@{source=$Source;reason='file_too_large';size_bytes=$Item.Length};return};if(($script:Total+$Item.Length)-gt$MaxTotal){$script:Excluded+=,[ordered]@{source=$Source;reason='bundle_budget_reached';size_bytes=$Item.Length};return};$Destination=Join-Path $Stage $Relative;Ensure-Dir (Split-Path -Parent $Destination);Copy-Item -LiteralPath $Source -Destination $Destination -Force;$script:Total+=$Item.Length;$script:Included+=,[ordered]@{source=$Source;path=($Relative-replace'\\','/');category=$Category;size_bytes=$Item.Length}}
function Add-Tree([string]$SourceRoot,[string]$DestinationRoot,[string]$Category){if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)){return};Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue|Sort-Object FullName|ForEach-Object{$RelativePath=[IO.Path]::GetRelativePath($SourceRoot,$_.FullName);Add-TextFile $_.FullName (Join-Path $DestinationRoot $RelativePath) $Category}}
function Invoke-Git([string]$GitRoot,[string[]]$GitArguments){$Output=@(& git -C $GitRoot @GitArguments 2>&1);if($LASTEXITCODE-ne0){throw "git $($GitArguments -join ' ') failed: $($Output-join[Environment]::NewLine)"};return($Output-join"`n").Trim()}
try{
 Ensure-Dir $Stage;Ensure-Dir $OutputRoot
 $Agy=Join-Path $Project '.agy';$SourceRoot=$Project
 $LeasePath=Join-Path $Agy 'EXECUTION_LEASE.json';if(Test-Path -LiteralPath $LeasePath -PathType Leaf){try{$Lease=Get-Content -LiteralPath $LeasePath -Raw -Encoding UTF8|ConvertFrom-Json;if($Lease.worktree_root-and(Test-Path -LiteralPath ([string]$Lease.worktree_root) -PathType Container)){$SourceRoot=(Resolve-Path -LiteralPath ([string]$Lease.worktree_root)).Path}}catch{}}
 $ProjectGit=[ordered]@{root=$Project;git_root=Invoke-Git $Project @('rev-parse','--show-toplevel');branch=Invoke-Git $Project @('branch','--show-current');head=Invoke-Git $Project @('rev-parse','HEAD');status_porcelain=Invoke-Git $Project @('status','--porcelain=v1','--untracked-files=all');worktrees_porcelain=Invoke-Git $Project @('worktree','list','--porcelain')}
 $SourceGit=[ordered]@{root=$SourceRoot;git_root=Invoke-Git $SourceRoot @('rev-parse','--show-toplevel');branch=Invoke-Git $SourceRoot @('branch','--show-current');head=Invoke-Git $SourceRoot @('rev-parse','HEAD');status_porcelain=Invoke-Git $SourceRoot @('status','--porcelain=v1','--untracked-files=all');diff=Invoke-Git $SourceRoot @('diff','--no-ext-diff','--');diff_cached=Invoke-Git $SourceRoot @('diff','--cached','--no-ext-diff','--')}
 Write-Utf8 (Join-Path $Stage 'GIT\PROJECT_RUNTIME.json') ($ProjectGit|ConvertTo-Json -Depth 20)
 Write-Utf8 (Join-Path $Stage 'GIT\SOURCE_WORKTREE.json') ($SourceGit|ConvertTo-Json -Depth 20)
 $CurrentGoal='No active work item.';$WorkItemStatus='none';$NextRoute=$null
 $WorkItemPath=Join-Path $Agy 'WORK_ITEM.json';if(Test-Path -LiteralPath $WorkItemPath -PathType Leaf){$WorkItem=Get-Content -LiteralPath $WorkItemPath -Raw -Encoding UTF8|ConvertFrom-Json;$CurrentGoal=[string]$WorkItem.goal;$WorkItemStatus=[string]$WorkItem.status}
 $NextPath=Join-Path $Agy 'NEXT_ACTION.json';if(Test-Path -LiteralPath $NextPath -PathType Leaf){$Next=Get-Content -LiteralPath $NextPath -Raw -Encoding UTF8|ConvertFrom-Json;$NextRoute=$Next.route}
 $Migration=@"
# Owner-Autonomy Migration

Pipeline 1.2.8, runtime 1.2.8 and Companion 1.2.8 are active.

The previous Companion chat is retired. Resume the current product state from the machine files in this archive. Routine repair, audit correction, verification retry and evidence rebuild continue automatically while progress is observed. Ask the owner only for a real product or risk decision.

Owner-facing comments must be concise, accessible Russian. Put technical details into the downloadable Action Packet.
"@
 Write-Utf8 (Join-Path $Stage 'MIGRATION_NOTE.md') $Migration.Trim()
 $StateSummary=[ordered]@{schema_version='1.2.8';project=$LogicalName;project_id=$ProjectId;runtime_root=$Project;source_root=$SourceRoot;pipeline_package='1.2.8';runtime_version='1.2.8';companion_version='1.2.8';current_goal=$CurrentGoal;work_item_status=$WorkItemStatus;next_route=$NextRoute;generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
 Write-Utf8 (Join-Path $Stage 'CURRENT_STATE.json') ($StateSummary|ConvertTo-Json -Depth 20)
 Add-Tree $Agy 'STATE\.agy' 'project_state'
 foreach($RelativePath in @('.agents\AGENTS.md','.agents\COMMAND_INVENTORY.json','.agents\hooks.json','.agents\rules\05-runtime-contract.md','.agents\rules\61-autonomous-audit-convergence.md','.agents\rules\62-protected-reviewer.md','.agents\rules\63-scientific-stage-firewall.md','.agents\rules\64-owner-autonomy.md','.agents\workflows\nextphase.md','.agents\workflows\auditphase.md','.agents\workflows\fixcritical.md')){Add-TextFile (Join-Path $Project $RelativePath) (Join-Path 'RUNTIME' $RelativePath) 'runtime_contract'}
 foreach($DirectoryName in @('src','tests','scripts','docs')){Add-Tree (Join-Path $SourceRoot $DirectoryName) (Join-Path 'PROJECT_SOURCE' $DirectoryName) 'project_source'}
 foreach($Name in @('package.json','package-lock.json','tsconfig.json','vite.config.ts','README.md','AGENTS.md')){Add-TextFile (Join-Path $SourceRoot $Name) (Join-Path 'PROJECT_SOURCE' $Name) 'project_root'}
 $LatestHandoff=$null;$HandoffProjectRoot=Join-Path $HandoffRoot (Join-Path 'handoffs' $LogicalName);if(Test-Path -LiteralPath $HandoffProjectRoot -PathType Container){$LatestHandoff=Get-ChildItem -LiteralPath $HandoffProjectRoot -Recurse -File -Filter 'LATEST_CONTEXT.zip' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1}
 if($LatestHandoff-and$LatestHandoff.Length-le25MB){Ensure-Dir (Join-Path $Stage 'LATEST_HANDOFF');Copy-Item -LiteralPath $LatestHandoff.FullName -Destination (Join-Path $Stage 'LATEST_HANDOFF\LATEST_CONTEXT.zip') -Force;$script:Included+=,[ordered]@{source=$LatestHandoff.FullName;path='LATEST_HANDOFF/LATEST_CONTEXT.zip';category='latest_handoff';size_bytes=$LatestHandoff.Length};$Extract=Join-Path $env:TEMP ('agentic-handoff-extract-'+[guid]::NewGuid().ToString('N'));try{Expand-Archive -LiteralPath $LatestHandoff.FullName -DestinationPath $Extract -Force;foreach($RelativePath in @('COMPANION_ENTRY.md','CURRENT_AUTHORITY.json','CONTEXT_READINESS.json','RUNTIME_STATUS.json','CONTINUATION_POLICY.json','RESULT_IDENTITY.json','GIT_OVERVIEW.json','TOUCHED_FILES.json')){Add-TextFile (Join-Path $Extract $RelativePath) (Join-Path 'LATEST_HANDOFF\EXTRACTED' $RelativePath) 'latest_handoff_authority'};Add-Tree (Join-Path $Extract 'SESSION_DELTA') 'LATEST_HANDOFF\EXTRACTED\SESSION_DELTA' 'latest_session_delta'}finally{Remove-Item -LiteralPath $Extract -Recurse -Force -ErrorAction SilentlyContinue}}
 $Entry=@"
# Companion Restart Bootstrap

Project: $LogicalName

Read in this order:

1. `MIGRATION_NOTE.md`
2. `CURRENT_STATE.json`
3. `STATE/.agy/WORK_ITEM.json`, `PROGRESS_STATE.json`, `NEXT_ACTION.json`, `FINDINGS.json` and current authority files when present
4. `GIT/PROJECT_RUNTIME.json` and `GIT/SOURCE_WORKTREE.json`
5. `LATEST_HANDOFF/EXTRACTED/SESSION_DELTA` and other current handoff files
6. `PROJECT_SOURCE/` only as needed

Treat the old Companion conversation as retired. Do not ask for another repair-iteration authorization. First explain the current product state in plain Russian and wait only if a true owner decision is required. When work can continue, create one downloadable `AGENTIC_ACTION_PACKET_*.json`; the local Action Bridge will deliver it to Antigravity.
"@
 Write-Utf8 (Join-Path $Stage 'COMPANION_ENTRY.md') $Entry.Trim()
 Write-Utf8 (Join-Path $Stage 'INCLUDED_FILES.json') ($Included|ConvertTo-Json -Depth 10)
 Write-Utf8 (Join-Path $Stage 'EXCLUSIONS.json') ($Excluded|ConvertTo-Json -Depth 10)
 $ManifestFiles=@(Get-ChildItem -LiteralPath $Stage -Recurse -File|Where-Object{$_.Name-ne'MANIFEST.json'}|Sort-Object FullName|ForEach-Object{[ordered]@{path=[IO.Path]::GetRelativePath($Stage,$_.FullName).Replace('\\','/');size_bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
 $Manifest=[ordered]@{schema_version='1.2.8';artifact='COMPANION_RESTART_BOOTSTRAP';project_id=$ProjectId;project=$LogicalName;pipeline_package='1.2.8';runtime_version='1.2.8';companion_version='1.2.8';file_count=$ManifestFiles.Count;files=$ManifestFiles;generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
 Write-Utf8 (Join-Path $Stage 'MANIFEST.json') ($Manifest|ConvertTo-Json -Depth 20)
 Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
 Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $ZipPath -CompressionLevel Optimal -Force
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $Archive=[IO.Compression.ZipFile]::OpenRead($ZipPath);try{if($Archive.Entries.Count-lt1){throw 'Bootstrap ZIP is empty.'};$Unsafe=@($Archive.Entries|Where-Object{$_.FullName-match'(^|/)\.\.(/|$)'-or$_.FullName-match'^[A-Za-z]:'-or$_.FullName.StartsWith('/')-or$_.FullName.StartsWith('\\')});if($Unsafe.Count){throw 'Bootstrap ZIP contains unsafe paths.'}}finally{$Archive.Dispose()}
 $Check=Join-Path $env:TEMP ('agentic-bootstrap-check-'+[guid]::NewGuid().ToString('N'));try{Expand-Archive -LiteralPath $ZipPath -DestinationPath $Check -Force;$CheckedManifest=Get-Content -LiteralPath (Join-Path $Check 'MANIFEST.json') -Raw -Encoding UTF8|ConvertFrom-Json;foreach($File in @($CheckedManifest.files)){$Full=Join-Path $Check ([string]$File.path);if (-not (Test-Path -LiteralPath $Full -PathType Leaf)){throw "Missing bootstrap member: $($File.path)"};if((Get-Item -LiteralPath $Full).Length-ne[int64]$File.size_bytes){throw "Bootstrap size mismatch: $($File.path)"};if((Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$File.sha256){throw "Bootstrap SHA mismatch: $($File.path)"}}}finally{Remove-Item -LiteralPath $Check -Recurse -Force -ErrorAction SilentlyContinue}
 $Result=[ordered]@{schema_version='1.2.8';status='PASS';project_id=$ProjectId;project=$LogicalName;zip_path=$ZipPath;zip_sha256=(Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant();file_count=$ManifestFiles.Count;source_root=$SourceRoot;generated_at_utc=(Get-Date).ToUniversalTime().ToString('o')}
 Write-Utf8 $ResultPath ($Result|ConvertTo-Json -Depth 10)
 Write-Host 'COMPANION RESTART BOOTSTRAP READY.' -ForegroundColor Green
 Write-Host "Output: $ZipPath"
 if($OpenFolder){Start-Process explorer.exe -ArgumentList "/select,`"$ZipPath`""}
}finally{Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue}
