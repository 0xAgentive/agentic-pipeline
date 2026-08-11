[CmdletBinding()]
param([string]$RepoRoot='.')
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $RepoRoot).Path
$HooksPath=Join-Path $Root 'templates\agy-project-base\.agents\hooks.json'
$Hooks=Get-Content -LiteralPath $HooksPath -Raw -Encoding UTF8|ConvertFrom-Json
$Group=$Hooks.'agentic-owner-autonomy'
if(-not$Group-or$Group.enabled-ne$true){throw 'Active owner-autonomy hook group is missing.'}
foreach($Name in @('PreToolUse','PostToolUse','PreInvocation','Stop')){if(-not$Group.PSObject.Properties[$Name]-or@($Group.$Name).Count-eq0){throw "Hook event missing: $Name"}}
$Node=(Get-Command node -ErrorAction Stop).Source
$TestScript=@'
const fs=require('fs'),os=require('os'),path=require('path');const root=process.env.AGENTIC_REPO_ROOT;
const c=require(path.join(root,'scripts/control-plane/autonomous-convergence.cjs'));const p=require(path.join(root,'scripts/control-plane/progress-guard.cjs'));const f=require(path.join(root,'scripts/control-plane/validate-findings.cjs'));const s=require(path.join(root,'scripts/control-plane/validate-owner-summary.cjs'));const a=require(path.join(root,'scripts/control-plane/action-packet.cjs'));
const d=c.resolveContinuationPolicy({assuranceMode:'guarded',openFindings:[{lifecycle_status:'open_confirmed',materiality:'product_blocker'}],progressState:{status:'progressing',observations_count:99}});if(d.action!=='continue_grouped_repair'||d.limit!==null)throw new Error('numeric authorization active');
const finding={finding_id:'A',lifecycle_status:'open_confirmed',materiality:'product_blocker'};const first=p.updateProgress({},{work_item_id:'x',findings:[finding],tests:[],files:[{path:'a',sha256:'1'}]});const churn=p.updateProgress(first,{work_item_id:'x',findings:[finding],tests:[],files:[{path:'a',sha256:'2'}]});if(churn.consecutive_no_progress!==1)throw new Error('churn counted as progress');
const bad=f.validateSet([{finding_id:'A',title:'x',category:'delivery',severity:'high',lifecycle_status:'bad',phase_classification:'current_phase_blocker',materiality:'product_blocker',auto_repairable:true,owner_decision_required:false}]);if(bad.ok)throw new Error('malformed finding accepted');
const plain='## Что происходит\nПроверка продукта продолжается.\n## Что уже сделано\nОсновная ошибка исправлена.\n## Что будет дальше\nСистема сама завершит проверку.\n## Нужно ли что-то от владельца\nНичего.';if(!s.validate(plain).ok)throw new Error('plain owner summary rejected');
const packet={schema_version:'1.2.9',ecosystem_version:'1.2.23',packet_format:'single_json',packet_id:'packet-contract-001',project_id:'generic-project',operation:'continue_work_item',route:'/fixcritical',work_item_id:'wi-1',goal_epoch:3,goal:'Continue current goal',assurance_mode:'guarded',owner_approved:true,owner_interaction_policy:'hard_stop_only',scope_binding:'executor_discovery',technical_task_markdown:'# Task\nContinue current work.',owner_summary_ru:plain,created_at_utc:new Date(Date.now()-1000).toISOString(),expires_at_utc:new Date(Date.now()+3600000).toISOString()};if(!a.validatePacketObject(packet).ok)throw new Error('valid token-free JSON packet rejected');packet.expires_at_utc=new Date(Date.now()-100).toISOString();if(a.validatePacketObject(packet).ok)throw new Error('expired packet accepted');console.log(JSON.stringify({ok:true,checks:6}));
'@
$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('owner-autonomy-contract-'+[guid]::NewGuid().ToString('N'))
$Temp=Join-Path $TempRoot 'owner-autonomy-contract-test.cjs'
try{New-Item -ItemType Directory -Force $TempRoot|Out-Null;[IO.File]::WriteAllText($Temp,$TestScript,[Text.UTF8Encoding]::new($false));$env:AGENTIC_REPO_ROOT=$Root;& $Node $Temp;if($LASTEXITCODE-ne0){throw 'Owner-autonomy Node contracts failed.'}}finally{Remove-Item Env:AGENTIC_REPO_ROOT -ErrorAction SilentlyContinue;Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue}
$PythonCommand=Get-Command python -ErrorAction SilentlyContinue|Select-Object -First 1
if(-not$PythonCommand){$PythonCommand=Get-Command py -ErrorAction Stop|Select-Object -First 1}
$CacheRoot=Join-Path ([IO.Path]::GetTempPath()) ('agentic-python-cache-'+[guid]::NewGuid().ToString('N'))
$PreviousCachePrefix=$env:PYTHONPYCACHEPREFIX
try{$env:PYTHONPYCACHEPREFIX=$CacheRoot;& $PythonCommand.Source -m py_compile (Join-Path $Root 'scripts\bridge\companion_action_bridge.py');if($LASTEXITCODE-ne0){throw 'Action Bridge Python compile failed.'}}finally{$env:PYTHONPYCACHEPREFIX=$PreviousCachePrefix;Remove-Item $CacheRoot -Recurse -Force -ErrorAction SilentlyContinue}
& (Join-Path $Root 'templates/agy-project-base/.agents/hooks/Test-HookContract.ps1') -ProjectRoot (Join-Path $Root 'templates/agy-project-base')
if($LASTEXITCODE-ne0){throw 'Active hook behavioral contract failed.'}
Write-Host 'Owner-autonomy contracts passed.'
