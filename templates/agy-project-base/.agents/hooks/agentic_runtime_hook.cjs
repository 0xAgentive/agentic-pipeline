#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const cp = require('child_process');
const event = process.argv[2] || '';

function input(){const raw=fs.readFileSync(0,'utf8');return raw.trim()?JSON.parse(raw):{};}
function output(value){process.stdout.write(JSON.stringify(value));}
function json(file){return JSON.parse(fs.readFileSync(file,'utf8'));}
function hashFile(file){return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');}
function hashText(text){return crypto.createHash('sha256').update(String(text),'utf8').digest('hex');}
function norm(value){return path.resolve(value).replace(/\\/g,'/').replace(/\/$/,'').toLowerCase();}
function within(root,candidate){const r=norm(root),c=norm(candidate);return c===r||c.startsWith(`${r}/`);}
function atomic(file,value){fs.mkdirSync(path.dirname(file),{recursive:true});const temp=`${file}.tmp-${process.pid}-${Date.now()}`;fs.writeFileSync(temp,`${JSON.stringify(value,null,2)}\n`,'utf8');fs.renameSync(temp,file);}
function append(file,value){fs.mkdirSync(path.dirname(file),{recursive:true});fs.appendFileSync(file,`${JSON.stringify(value)}\n`,'utf8');}
function git(root,args){const result=cp.spawnSync('git',['-C',root,...args],{encoding:'utf8',windowsHide:true});if(result.status!==0)throw new Error(`GIT_IDENTITY_FAILED:${String(result.stderr||result.stdout||'').trim()}`);return String(result.stdout||'').trim();}
function projectRoots(payload){
  const found=[];
  for(const raw of payload.workspacePaths||[]){
    if(!raw)continue;
    let current=path.resolve(raw);
    try{if(fs.existsSync(current)&&fs.statSync(current).isFile())current=path.dirname(current);}catch{}
    while(current&&current!==path.dirname(current)){
      if(fs.existsSync(path.join(current,'.agy'))&&fs.existsSync(path.join(current,'.agents'))){found.push(current);break;}
      current=path.dirname(current);
    }
  }
  return [...new Map(found.map(item=>[norm(item),item])).values()];
}
function rootForCandidate(payload,candidate){
  if(candidate){
    const absolute=path.resolve(candidate);
    const roots=projectRoots(payload).filter(root=>within(root,absolute));
    if(roots.length===1)return roots[0];
    let current=absolute;
    try{if(fs.existsSync(current)&&fs.statSync(current).isFile())current=path.dirname(current);}catch{}
    while(current&&current!==path.dirname(current)){
      if(fs.existsSync(path.join(current,'.agy'))&&fs.existsSync(path.join(current,'.agents')))return current;
      current=path.dirname(current);
    }
  }
  const roots=projectRoots(payload);
  return roots.length===1?roots[0]:null;
}
function uniqueRoot(payload,predicate){const roots=projectRoots(payload).filter(predicate);return roots.length===1?roots[0]:null;}
function relative(root,candidate){if(!within(root,candidate))throw new Error('PATH_OUTSIDE_PROJECT');return path.relative(root,path.resolve(candidate)).replace(/\\/g,'/');}
function glob(pattern){let text=String(pattern||'').replace(/\\/g,'/').replace(/^\.\//,'');text=text.replace(/[.+^${}()|[\]\\]/g,'\\$&').replace(/\*\*/g,'§§').replace(/\*/g,'[^/]*').replace(/§§/g,'.*');return new RegExp(`^${text}$`,'i');}
function matches(value,patterns){return (patterns||[]).some(pattern=>glob(pattern).test(value));}
function target(payload){const a=payload.toolCall?.args||{};return a.TargetFile||a.targetFile||a.FilePath||a.filePath||a.file_path||a.path||null;}
function authority(root){const agy=path.join(root,'.agy');const files={workItem:path.join(agy,'WORK_ITEM.json'),scope:path.join(agy,'EXECUTION_SCOPE.json'),lease:path.join(agy,'EXECUTION_LEASE.json'),firewall:path.join(agy,'STAGE_FIREWALL.json'),workTx:path.join(agy,'WORK_ITEM_TRANSACTION.json'),authorityTx:path.join(agy,'EXECUTION_AUTHORITY_TRANSACTION.json')};for(const [key,file] of Object.entries(files))if(!fs.existsSync(file))throw new Error(`${key.toUpperCase()}_MISSING`);return{root,files,workItem:json(files.workItem),scope:json(files.scope),lease:json(files.lease),firewall:json(files.firewall),workTx:json(files.workTx),authorityTx:json(files.authorityTx)};}
function validate(a){
  const {root,files,workItem,scope,lease,firewall,workTx,authorityTx}=a;
  if(workItem.owner_approved!==true)throw new Error('WORK_ITEM_NOT_OWNER_APPROVED');
  if(workTx.status!=='committed'||String(workTx.work_item_id)!==String(workItem.work_item_id))throw new Error('WORK_ITEM_TRANSACTION_NOT_COMMITTED');
  if(authorityTx.status!=='committed'||String(authorityTx.work_item_id)!==String(workItem.work_item_id)||String(authorityTx.lease_id)!==String(lease.lease_id))throw new Error('EXECUTION_AUTHORITY_TRANSACTION_NOT_COMMITTED');
  if(scope.status!=='exact'||lease.status!=='active')throw new Error('EXECUTION_AUTHORITY_NOT_ACTIVE');
  if(String(workItem.work_item_id)!==String(scope.work_item_id)||String(workItem.work_item_id)!==String(lease.work_item_id))throw new Error('WORK_ITEM_ID_MISMATCH');
  if(Number(workItem.goal_epoch)!==Number(lease.goal_epoch))throw new Error('GOAL_EPOCH_MISMATCH');
  if(firewall.status!=='active'||String(firewall.work_item_id)!==String(workItem.work_item_id))throw new Error('STAGE_FIREWALL_NOT_ACTIVE');
  if(norm(root)!==norm(lease.project_root)||norm(root)!==norm(lease.worktree_root))throw new Error('WORKTREE_ROOT_MISMATCH');
  if(lease.owner_goal_sha256!==hashText(String(workItem.goal)))throw new Error('OWNER_GOAL_FINGERPRINT_MISMATCH');
  if(lease.execution_scope_sha256!==hashFile(files.scope))throw new Error('EXECUTION_SCOPE_FINGERPRINT_MISMATCH');
  if(norm(git(root,['rev-parse','--show-toplevel']))!==norm(root))throw new Error('GIT_ROOT_MISMATCH');
  if(String(lease.branch)!==git(root,['branch','--show-current']))throw new Error('BRANCH_MISMATCH');
  if(lease.first_write_started!==true&&String(lease.baseline_head)!==git(root,['rev-parse','HEAD']))throw new Error('BASELINE_HEAD_MISMATCH');
  for(const name of ['EXECUTION_SCOPE.json','STAGE_FIREWALL.json']){const expected=authorityTx.files?.[name]?.sha256;const current=path.join(root,'.agy',name);if(!expected||!fs.existsSync(current)||hashFile(current)!==String(expected))throw new Error(`AUTHORITY_FILE_DRIFT:${name}`);}
}
function allow(reason){output({decision:'allow',reason});}
function deny(reason){output({decision:'deny',reason});}
function pending(root,payload){const conversation=String(payload.conversationId||'unknown').replace(/[^A-Za-z0-9_.-]/g,'_');const step=Number.isInteger(payload.stepIdx)?payload.stepIdx:'unknown';return path.join(root,'.agy','.hook_pending',`${conversation}-${step}.json`);}
function savePending(root,payload,kind,data){atomic(pending(root,payload),{kind,data,created_at_utc:new Date().toISOString()});}
function takePending(root,payload){const file=pending(root,payload);if(!fs.existsSync(file))return null;const value=json(file);fs.rmSync(file,{force:true});return value;}
function prewrite(payload){const file=target(payload);const root=rootForCandidate(payload,file);if(!file||!root)return deny('Запись остановлена: точный проект или файл не определён.');try{const a=authority(root);validate(a);const rel=relative(root,file);if(!matches(rel,a.lease.allowed_paths))return deny(`Файл вне разрешённой области текущей задачи: ${rel}`);if(matches(rel,a.firewall.protected_path_patterns||[])&&a.firewall.algorithm_repair_authorized!==true)return deny(`Защищённый аналитический файл не разрешён текущей задачей: ${rel}`);if(a.lease.first_write_started!==true){a.lease.first_write_started=true;a.lease.first_write_started_at_utc=new Date().toISOString();atomic(path.join(root,'.agy','EXECUTION_LEASE.json'),a.lease);}savePending(root,payload,'write',{file,rel});allow('Точная область текущей задачи разрешает изменение файла.');}catch(error){deny(`Запись остановлена: ${error.message}`);}}
function precommand(payload){const a=payload.toolCall?.args||{};const command=String(a.CommandLine||'');const cwd=String(a.Cwd||'');const root=rootForCandidate(payload,cwd||null);if(!root)return deny('Команда остановлена: точный проект не определён.');const destructive=/(git\s+(reset\s+--hard|clean\s+-|checkout\s+--|push\s+--force)|format\s+|diskpart|drop\s+(table|database)|remove-item\b[^\r\n]*-recurse|rm\s+-rf|del\s+\/[sq])/i;if(destructive.test(command))return output({decision:'force_ask',reason:'Команда может необратимо изменить данные и требует явного решения владельца.'});const readOnly=/^\s*(git\s+(status|diff|rev-parse|log|show|branch|worktree\s+list)|get-content|get-childitem|test-path|select-string|node\s+--check|npm\s+(test|run\s+(test|typecheck))|npx\s+vitest|python\s+(-m\s+pytest|.*--version)|pwsh\s+.*test-[^\s]+\.ps1)\b/i;const control=/(Activate-ActionPacket|Start-WorkItemTransaction|Bind-ExecutionScopeTransaction|Validate-ControlPlaneState|Test-ExecutionLease|Test-FindingSet|Publish-AuditCoverageMatrix|Register-FindingDelta|Register-Progress|Publish-CandidateManifest|Publish-NextAction|Migrate-ActiveWorkItemToProgressGuard|Compile-ResultAuthority)\.ps1/i;if(readOnly.test(command)||control.test(command)){savePending(root,payload,'command',{command,cwd,readOnly:true});return allow('Разрешённая проверочная или управляющая команда.');}try{const auth=authority(root);validate(auth);if((auth.lease.allowed_command_patterns||[]).some(pattern=>new RegExp(pattern,'i').test(command))){savePending(root,payload,'command',{command,cwd,readOnly:false});return allow('Команда входит в точную область текущей задачи.');}deny('Команда не входит в точную область текущей задачи.');}catch(error){deny(`Команда остановлена: ${error.message}`);}}
function post(payload,kind){const a=payload.toolCall?.args||{};const candidate=kind==='write'?target(payload):String(a.Cwd||'');const root=rootForCandidate(payload,candidate||null);if(!root)return output({});try{const record=takePending(root,payload);if(!record||record.kind!==kind)return output({});if(kind==='write'){let digest=null;if(!payload.error&&fs.existsSync(record.data.file)&&fs.statSync(record.data.file).isFile())digest=hashFile(record.data.file);append(path.join(root,'.agy','WRITE_LEDGER.ndjson'),{at_utc:new Date().toISOString(),path:record.data.rel,success:!payload.error,sha256:digest,error:String(payload.error||'')});if(!payload.error)atomic(path.join(root,'.agy','CANDIDATE_MANIFEST_STATUS.json'),{schema_version:'1.1.0',status:'invalidated',manifest_path:null,manifest_sha256:null,invalidated_by:[record.data.rel],updated_at_utc:new Date().toISOString()});}else{append(path.join(root,'.agy','COMMAND_LEDGER.ndjson'),{at_utc:new Date().toISOString(),command:record.data.command,cwd:record.data.cwd,success:!payload.error,error:String(payload.error||'')});if(!payload.error&&!record.data.readOnly)atomic(path.join(root,'.agy','CANDIDATE_MANIFEST_STATUS.json'),{schema_version:'1.1.0',status:'invalidated',manifest_path:null,manifest_sha256:null,invalidated_by:['run_command'],updated_at_utc:new Date().toISOString()});}}catch{}output({});}
function activatePacket(root){const receiptFile=path.join(root,'.agy','ACTION_PACKET_RECEIPT.json');const packetDir=path.join(root,'.agy','inbox','ACTIVE_ACTION_PACKET');if(!fs.existsSync(receiptFile)||!fs.existsSync(path.join(packetDir,'AGENT_TASK.md')))return null;const receipt=json(receiptFile);if(['activated','injected'].includes(receipt.status))return receipt;if(!['imported','pending'].includes(receipt.status))return null;const script=path.join(root,'scripts','windows','companion','Activate-ActionPacket.ps1');if(!fs.existsSync(script))throw new Error('ACTION_PACKET_ACTIVATOR_MISSING');const result=cp.spawnSync('pwsh',['-NoProfile','-ExecutionPolicy','Bypass','-File',script,'-ProjectRoot',root,'-PacketDirectory',packetDir,'-Apply'],{cwd:root,encoding:'utf8',windowsHide:true,timeout:20000});if(result.status!==0)throw new Error(`ACTION_PACKET_ACTIVATION_FAILED:${String(result.stderr||result.stdout||'').trim()}`);return json(receiptFile);}
function preinvocation(payload){const root=uniqueRoot(payload,item=>fs.existsSync(path.join(item,'.agy','ACTION_PACKET_RECEIPT.json'))&&fs.existsSync(path.join(item,'.agy','inbox','ACTIVE_ACTION_PACKET','AGENT_TASK.md')));if(!root)return output({injectSteps:[]});try{const receipt=activatePacket(root);if(!receipt||receipt.injected_at_utc)return output({injectSteps:[]});receipt.status='injected';receipt.injected_at_utc=new Date().toISOString();atomic(path.join(root,'.agy','ACTION_PACKET_RECEIPT.json'),receipt);output({injectSteps:[{ephemeralMessage:'A validated owner-approved Action Packet has been activated. Read .agy/inbox/ACTIVE_ACTION_PACKET/AGENT_TASK.md as the sole active technical task. Continue automatically inside its exact scope. Routine repair, audit correction, verification retry and evidence rebuild do not require owner approval.'}]});}catch(error){output({injectSteps:[{ephemeralMessage:`Action Packet activation stopped safely: ${error.message}`}]});}}
function stop(payload){if(payload.fullyIdle!==true||String(payload.terminationReason||'')!=='model_stop')return output({decision:'stop'});const root=uniqueRoot(payload,item=>{const file=path.join(item,'.agy','NEXT_ACTION.json');if(!fs.existsSync(file))return false;try{const next=json(file);return next.auto_continue===true&&Boolean(next.route);}catch{return false;}});if(!root)return output({decision:'stop'});try{const next=json(path.join(root,'.agy','NEXT_ACTION.json'));const progressFile=path.join(root,'.agy','PROGRESS_STATE.json');const progress=fs.existsSync(progressFile)?json(progressFile):null;if(next.owner_decision_required===true||progress?.owner_decision_required===true||progress?.status==='stalled')return output({decision:'stop'});return output({decision:'continue',reason:`Continue the same owner-approved work item automatically. Follow ${next.route} from .agy/NEXT_ACTION.json. Do not ask for a repair-budget exception.`});}catch{return output({decision:'stop'});}}
try{const payload=input();if(event==='prewrite')prewrite(payload);else if(event==='precommand')precommand(payload);else if(event==='postwrite')post(payload,'write');else if(event==='postcommand')post(payload,'command');else if(event==='preinvocation')preinvocation(payload);else if(event==='stop')stop(payload);else output({});}catch(error){if(event==='prewrite'||event==='precommand')deny(`Hook failure: ${error.message}`);else output(event==='stop'?{decision:'stop'}:{});}
