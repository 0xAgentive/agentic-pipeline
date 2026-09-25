import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {spawnSync,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {DurableTransport,readRegular,parsePacketBytes,hash} from './transport.mjs';
import {CdpBrowser} from './cdp-adapter.mjs';
const here=path.dirname(fileURLToPath(import.meta.url)), require=createRequire(import.meta.url);
const {EffectOwner}=require('../effect_owner.cjs');

export function resolveTransportConfiguration(config) {
  const {runtimePath}=require('../runtime_paths.cjs');
  const opts=config.transportV2||{};
  const paths={repoRoot:runtimePath('AGENTIC_PIPELINE_ROOT'),stateRoot:runtimePath('AGENTIC_STATE_ROOT'),registry:runtimePath('AGENTIC_PROJECT_REGISTRY'),python:runtimePath('AGENTIC_PYTHON'),configPath:runtimePath('ANTIGRAVITY_DATA_ROOT','companion_bridge_config.json'),runtimeDir:runtimePath('AGENTIC_RUNTIME_SCRIPTS_DIR')};
  const configuredDb=process.env.AGENTIC_RECOVERY_DB;
  if(configuredDb!==undefined&&(!configuredDb.trim()||!path.isAbsolute(configuredDb)))throw new Error('INVALID_RECOVERY_DATABASE_PATH');
  paths.recoveryDatabase=configuredDb||path.join(paths.stateRoot,'RECOVERY_STATE.sqlite3');
  const same=(a,b)=>process.platform==='win32'?path.resolve(a).toLowerCase()===path.resolve(b).toLowerCase():path.resolve(a)===path.resolve(b);
  for(const key of ['repoRoot','stateRoot','registry','python','configPath','recoveryDatabase']) {
    if(opts[key]!==undefined&&(typeof opts[key]!=='string'||!same(opts[key],paths[key])))throw new Error('TRANSPORT_CONFIG_CONFLICT:'+key);
  }
  if(!same(paths.runtimeDir,path.resolve(here,'..')))throw new Error('RUNTIME_ENTRYPOINT_ROOT_MISMATCH');
  if(!process.env.PYTHONPYCACHEPREFIX) {
    const pycacheDir = path.join(paths.stateRoot, 'cache', 'pycache');
    process.env.PYTHONPYCACHEPREFIX = pycacheDir;
    try { fs.mkdirSync(pycacheDir, { recursive: true }); } catch {}
  }
  return {...paths,compilerExecutable:opts.compilerExecutable};
}

export async function advanceImportedRecord(transport,record) {
  if(record.state!=='PACKET_IMPORTED')return record;
  if(!record.artifact_path || !record.decision?.packet) {
    return transport.save(record,'WORK_COMPLETE',{hold_reason:null});
  }
  if(transport.local.isExecutionFinished?.(record)) {
    return transport.save(record,'WORK_COMPLETE',{execution_advancement:null,native_hold:null,execution_status:'finished_without_strict_advancement'});
  }
  try {
    const delivery=await transport.local.advancePacket(record);
    transport.save(record,'PACKET_IMPORTED',{native_delivery:delivery,native_hold:null});
  } catch(error){
    try {
      if(transport.local.isExecutionFinished?.(record)) {
        return transport.save(record,'WORK_COMPLETE',{execution_advancement:null,native_hold:null,execution_status:'finished_without_strict_advancement'});
      }
      const observed=transport.local.invoke('observe',record);
      if(observed?.observed_injection||observed?.observed_activation){
        try {
          const advance=await transport.local.advancement(record);
          if(advance?.advancement_allowed===true) {
            return transport.save(record,'WORK_COMPLETE',{execution_advancement:advance,native_hold:null});
          }
        } catch {}
        if(transport.local.isExecutionFinished?.(record)) {
          return transport.save(record,'WORK_COMPLETE',{execution_advancement:null,native_hold:null,execution_status:'finished_without_strict_advancement'});
        }
      }
    } catch {}
    transport.save(record,'PACKET_IMPORTED',{native_hold:error.code||error.message});
    return record;
  }
  const advance=await transport.local.advancement(record);
  if(advance?.advancement_allowed===true) return transport.save(record,'WORK_COMPLETE',{execution_advancement:advance});
  if(transport.local.isExecutionFinished?.(record)) {
    return transport.save(record,'WORK_COMPLETE',{execution_advancement:advance,execution_status:'finished_without_strict_advancement'});
  }
  return record;
}

export class LocalEvidence {
  constructor(config){Object.assign(this,config);}
  async validate(bytes,record) {
    const {validatePacketObject}=require(path.join(this.repoRoot,'scripts/control-plane/action-packet.cjs'));
    const packet = parsePacketBytes(bytes);
    const checked = validatePacketObject(packet, { allowCapability: true, projectRoot: this.projectRoot });
    const normPid = (p) => (p || '').toLowerCase().replace(/[-_ ]/g, '');
    const PROJECT_ALIASES = {
      'vitalis': ['huaweihealthexport', 'vitalis', 'huaweihealth'],
      'huaweihealthexport': ['huaweihealthexport', 'vitalis', 'huaweihealth'],
      'h10': ['h10athletecardiolab', 'h10', 'cardiolab', 'h10cardiolab'],
      'h10athletecardiolab': ['h10athletecardiolab', 'h10', 'cardiolab', 'h10cardiolab']
    };
    const incomingNorm = normPid(packet.project_id);
    const rootNorm = normPid(this.projectRootIdentity);
    const keyNorm = normPid(this.projectKey);
    const allowed = new Set([rootNorm, keyNorm, ...(PROJECT_ALIASES[keyNorm] || []), ...(PROJECT_ALIASES[rootNorm] || [])]);
    const projectMatches = allowed.has(incomingNorm);
    if(!checked.ok||!projectMatches||packet.packet_id!==record.decision.packet.packet_id) {
      console.error("PACKET_CONTRACT_INVALID details:", {
        checked_ok: checked.ok,
        checked_errors: checked.errors,
        projectMatches,
        packet_project_id: packet.project_id,
        expected_project_id: this.projectRootIdentity,
        projectKey: this.projectKey,
        packet_id: packet.packet_id,
        decision_packet_id: record.decision?.packet?.packet_id
      });
      throw new Error('PACKET_CONTRACT_INVALID');
    }
  }
  invoke(command,record) {
    const child=spawnSync(this.python,[path.join(here,'local-verifier.py')],{input:JSON.stringify({command,project_root:this.projectRoot,repo_root:this.repoRoot,registry:this.registry,state_root:this.stateRoot,artifact_path:record.artifact_path,binding:record.binding,decision:record.decision,recovery_database:this.recoveryDatabase,project_key:this.projectKey,native_conversation_id:this.nativeConversationId}),encoding:'utf8',timeout:30000,windowsHide:true,maxBuffer:1024*1024,env:{...process.env,PYTHONUTF8:'1'}});
    let result;try{result=JSON.parse(child.stdout);}catch{throw new Error('LOCAL_VERIFIER_UNAVAILABLE');}
    if(!result.ok)throw new Error(result.error||'LOCAL_VERIFICATION_FAILED');return result;
  }
  async importArtifact(file,record){record.artifact_path=file;const result=this.invoke('import',record);if(!result.facts?.bridge_receipt)throw new Error('IMPORT_RECEIPT_MISSING');return result.result;}
  async facts(record) {
    if(record.decision?.kind==='packet_ready'&&record.artifact_path){const result=this.invoke('observe',record);return {...record.facts,...result.facts};}
    if(record.decision?.kind==='completed') {
      const {collectCompletionEvidence}=require(path.join(this.repoRoot,'scripts/control-plane/evidence-observer.cjs'));
      const result=await collectCompletionEvidence({projectRoot:this.projectRoot,binding:record.binding,decision:record.decision,compilerExecutable:this.compilerExecutable||'pwsh'});
      if(!result.ok)return {};return result.facts;
    }
    return {};
  }
  async advancement(record) {
    const {collectExecutionAdvance}=require(path.join(this.repoRoot,'scripts/control-plane/evidence-observer.cjs'));
    return collectExecutionAdvance({projectRoot:this.projectRoot,binding:record.binding,compilerExecutable:this.compilerExecutable||'pwsh'});
  }
  async advancePacket(record) {
    let observed=this.invoke('observe',record);
    if(!observed.facts?.bridge_receipt)throw new Error('IMPORTED_RECEIPT_REQUIRED');
    const expectedSourceSha = observed.facts?.bridge_receipt?.source_sha256 || record.decision.packet.sha256;
    const baseArgs=['--project-root',this.projectRoot,'--project-key',this.projectKey,'--recovery-db',this.recoveryDatabase,'--expected-packet-id',record.decision.packet.packet_id,'--expected-source-sha256',expectedSourceSha];
    const run=async(name,args)=>{
      try {
        const now=this.snapshot?.();
        if(now&&(now.is_standby!==false||now.projects?.[this.projectKey]?.is_paused||!Number.isSafeInteger(now.epoch)))throw new Error('NATIVE_PAUSE_HOLD');
        const epochArgs=now?['--expected-epoch',String(now.epoch)]:[];
        const result=await promisify(execFile)(this.python,[path.join(this.repoRoot,'scripts/bridge',name),...args,...epochArgs],{timeout:150000,windowsHide:true,maxBuffer:1024*1024,env:{...process.env,PYTHONUTF8:'1'}});
        const lines=result.stdout.trim().split(/\r?\n/),value=JSON.parse(lines.at(-1));
        if(value.status!=='PASS'||value.packet_id!==record.decision.packet.packet_id)throw new Error('NATIVE_PACKET_EFFECT_UNPROVEN');
        return value;
      }catch(error){
        let code='NATIVE_'+name.toUpperCase().replace(/[^A-Z]/g,'_')+'_HOLD';
        try{const reply=JSON.parse((error.stdout||'').trim().split(/\r?\n/).at(-1));const stable=reply.reason?.match(/^[A-Z][A-Z0-9_]+(?=:|$)/)?.[0];if(stable)code=stable;}catch{}
        if((error.stderr||'').includes('PowerShell 7 is required'))code='NATIVE_POWERSHELL_7_UNAVAILABLE';
        throw Object.assign(new Error(code),{code});
      }
    };
    const result={};
    // Import lease has already ACKed. Native adapters own their own final leases;
    // this caller must never hold another shared effect lease around them.
    if(!observed.observed_activation)result.activation=await run('activate_action_packet.py',[...baseArgs,'--apply']);
    observed=this.invoke('observe',record);
    if(!observed.observed_activation)throw new Error('ACTIVATION_RECEIPT_REQUIRED');
    if(!observed.observed_injection)result.injection=await run('inject_action_packet.py',[...baseArgs,'--config',this.configPath]);
    observed=this.invoke('observe',record);
    if(!observed.observed_injection)throw new Error('INJECTION_RECEIPT_REQUIRED');
    return {activation_result:result.activation,injection_result:result.injection,activation:'verified',delivery:observed.native_acceptance_only?'api_accepted':'delivered',execution:'not_observed'};
  }
  isExecutionFinished(record) {
    try {
      const targetPacketId = record?.decision?.packet?.packet_id;
      if (!targetPacketId) return false;

      const receiptPath = path.join(this.projectRoot, '.agy', 'ACTION_PACKET_RECEIPT.json');
      if (fs.existsSync(receiptPath)) {
        try {
          const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8').replace(/^\uFEFF/,''));
          if (receipt.packet_id === targetPacketId && (!receipt.activated_at_utc && receipt.status === 'imported')) {
            return false;
          }
        } catch {}
      }

      const workPath = path.join(this.projectRoot, '.agy', 'WORK_ITEM.json');
      if (!fs.existsSync(workPath)) return false;
      const work = JSON.parse(fs.readFileSync(workPath, 'utf8').replace(/^\uFEFF/,''));

      if (work.action_packet_id !== targetPacketId) {
        return false;
      }

      const nextActionPath = path.join(this.projectRoot, '.agy', 'NEXT_ACTION.json');
      if (!fs.existsSync(nextActionPath)) return false;
      const nextAction = JSON.parse(fs.readFileSync(nextActionPath, 'utf8').replace(/^\uFEFF/,''));
      const isFinishingRoute = nextAction.route === null || ['/auditphase', '/shipcheck', '/close'].includes(nextAction.route);
      if (!isFinishingRoute || nextAction.auto_continue === true) return false;

      const closurePath = path.join(this.projectRoot, '.agy', 'CLOSURE_STATE.json');
      if (fs.existsSync(closurePath)) {
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8').replace(/^\uFEFF/,''));
        if (closure.work_item_id === work.work_item_id && (closure.implementation_status === 'completed' || closure.next_owner_goal_allowed === true || closure.closure_reason === 'true_owner_decision_required' || nextAction.owner_decision_required === true)) {
          return true;
        }
      }
      const runPath = path.join(this.projectRoot, '.agy', 'RUN_RESULT.json');
      if (fs.existsSync(runPath)) {
        const run = JSON.parse(fs.readFileSync(runPath, 'utf8').replace(/^\uFEFF/,''));
        if (run.work_item_id === work.work_item_id && (run.implementation_status === 'completed' || nextAction.owner_decision_required === true)) {
          return true;
        }
      }
      if ((work.status === 'completed' || nextAction.owner_decision_required === true) && isFinishingRoute && nextAction.auto_continue !== true) {
        return true;
      }
    } catch {}
    return false;
  }
}

export function createTransportHost(api) {
  function settings(projectKey,conn) {
    const config=api.loadConfig(),comp=config.browser?.companions?.[projectKey];
    if(!comp?.projectPath||!comp.urlPattern)throw new Error('PROJECT_TRANSPORT_CONFIGURATION_REQUIRED');
    const resolved=resolveTransportConfiguration(config),{stateRoot,registry,repoRoot,python,recoveryDatabase,configPath,runtimeDir,compilerExecutable}=resolved;
    const rows=JSON.parse(readRegular(registry).toString('utf8')).projects;
    const projectRoot=fs.realpathSync(comp.projectPath),registered=rows?.filter(p=>fs.realpathSync(p.project_root)===projectRoot);
    if(registered?.length!==1||!registered[0].project_id)throw new Error('REGISTERED_PROJECT_IDENTITY_REQUIRED');
    const project={key:projectKey,project_id:registered[0].project_id,projectRoot,conversation_id:comp.urlPattern};
    if(!/^[a-zA-Z0-9-]+$/.test(project.conversation_id))throw new Error('EXACT_CONVERSATION_ID_REQUIRED');
    const local=new LocalEvidence({projectRoot,projectRootIdentity:project.project_id,projectKey,repoRoot,registry,stateRoot,python,recoveryDatabase,configPath,nativeConversationId:comp.antigravityConversationId,snapshot:api.getRecoverySnapshot,compilerExecutable});
    const browser=new CdpBrowser(conn,{downloadRoot:path.join(stateRoot,'transport-downloads')});
    const effects=new EffectOwner({database:recoveryDatabase,python,runtimeDir});
    const transport=new DurableTransport({database:path.join(stateRoot,'transport.sqlite3'),stateRoot:path.join(stateRoot,'transport'),effects,browser,local,snapshot:api.getRecoverySnapshot,project});
    return {transport,comp};
  }
  function publish(projectKey,record) {
    const seen=api.loadSeenPackets();const turns={WAIT_OWNER:'AWAITING_OWNER_INPUT',FAILED:'COMPANION_BLOCKED',WORK_COMPLETE:'READY_FOR_CONTEXT',CONTEXT_REQUIRED:'CONTEXT_REUPLOAD_REQUIRED',WAIT_EXTERNAL:'WAITING_EXTERNAL',PACKET_IMPORTED:'PACKET_IMPORTED'};
    seen[projectKey]={...seen[projectKey],decisionBinding:record.binding,decisionEvidence:record.facts||{},turnState:turns[record.state]||'AWAITING_COMPANION_PACKET',transportState:record.state,transportHoldReason:record.hold_reason||null,transportUserMessageId:record.user_message_id||null,transportAssistantMessageId:record.assistant_message_id||null,lastPushedZip:record.context_path};
    api.saveSeenPackets(seen);
  }
  async function session(projectKey,fn,existingConn) {
    const config=api.loadConfig(),comp=config.browser?.companions?.[projectKey];if(!comp)throw new Error('UNKNOWN_PROJECT');
    const resolved=resolveTransportConfiguration(config);
    const bootstrap=spawnSync(resolved.python,[path.join(resolved.runtimeDir,'native_health.py'),'--command','bootstrap','--project-key',projectKey,'--database',resolved.recoveryDatabase],{encoding:'utf8',timeout:15000,windowsHide:true,maxBuffer:1024*1024,env:{...process.env,PYTHONUTF8:'1'}});
    let identity;try{identity=JSON.parse(bootstrap.stdout);}catch{throw new Error('NATIVE_BOOTSTRAP_UNAVAILABLE');}
    if(bootstrap.status!==0||!['INITIALIZED','VERIFIED'].includes(identity.status))throw new Error(identity.reason||'NATIVE_BOOTSTRAP_HOLD');
    const conn=existingConn||await api.connectToTab(comp.urlPattern);
    let openedTransport;
    try{
      const state=settings(projectKey,conn);openedTransport=state.transport;
      const result=await fn(state);if(result?.binding)publish(projectKey,result);
      const packet=result?.artifact_path?parsePacketBytes(readRegular(result.artifact_path)):null;
      return {ok:['SENT','PACKET_IMPORTED','WORK_COMPLETE','WAIT_OWNER','WAIT_EXTERNAL'].includes(result?.state),projectKey,projectName:state.comp.name,state:result?.state,generating:Boolean(result?.generating),zipPath:result?.context_path,filePath:result?.artifact_path,fileName:packet?(result.decision?.packet?.file_name||path.basename(result.artifact_path)):result?.file_name,packetId:packet?.packet_id,route:packet?.route,packetJson:packet,record:result};
    }
    finally{openedTransport?.store.db.close();if(!existingConn)conn.close();}
  }
  return {
    async push(target,options={}) {
      const key=api.detectProjectKey(target),zip=target&&fs.existsSync(target)&&target.endsWith('.zip')?path.resolve(target):api.getLatestHandoffZip(key);
      if(!key||!zip)throw new Error('CONTEXT_PROJECT_UNRESOLVED');
      return session(key,async({transport,comp})=>{
        const current=transport.current();if(current?.state==='WAIT_OWNER'||current?.state==='WAIT_EXTERNAL')return current;
        const needsNudge = current?.hold_reason === 'PROMISED_ARTIFACT_MISSING_FROM_COMPANION' || current?.decision?.kind === 'context_reupload_required' || (current?.state === 'FAILED' && current?.hold_reason !== 'SEND_EXPIRED_NOT_PROVEN') || current?.state === 'PREPARED' || current?.state === 'CONTEXT_REQUIRED';
        if(!options.force && !needsNudge && current?.binding?.context_sha256 && hash(readRegular(zip))===current.binding.context_sha256) {
          // If the zip hash is byte-for-byte identical to the context already held by companion, do not push duplicate context.
          return current;
        }
        const directive=api.loadOwnerDirective();
        let prompt=`Прикреплен актуальный контекст проекта ${comp.name}. Идентификаторы и архив не доказывают исполнение, приёмку или готовность релиза.`;
        if(current?.hold_reason==='PROMISED_ARTIFACT_MISSING_FROM_COMPANION'){
          prompt=`ВНИМАНИЕ: В предыдущем ответе было заявлено решение packet_ready, но сам файл экшн-пакета фактически не был предоставлен (отсутствует тело JSON в коде). Обязательно выведите полный JSON экшн-пакета в блоке кода \`\`\`json ... \`\`\`!\n\n`+prompt;
        } else if(current?.decision?.kind==='context_reupload_required' || (current?.decision?.reason||'').includes('P5A')){
          prompt=`ВНИМАНИЕ: Пакет для следующей фазы (P5A) не был получен или исполнен средой Antigravity. Текущее состояние репозитория — успешно завершённая фаза P4. Не запрашивайте подтверждение P5A! Выдайте прямо сейчас решение packet_ready и полный JSON экшн-пакета для фазы P5A (Pre-packaging Final Source Acceptance) в блоке кода \`\`\`json ... \`\`\`!\n\n`+prompt;
        }
        if(directive?.active&&directive.text){
          prompt+='\n\nТребование владельца:\n'+directive.text.trim();
        }
        return transport.dispatch(zip,prompt);
      });
    },
    pull(projectKey){return session(projectKey,async({transport})=>advanceImportedRecord(transport,await transport.pull()));},
    tick(projectKey,conn){return session(projectKey,async({transport,comp})=>{
      const record=await advanceImportedRecord(transport,await transport.pull());
      if(record.state==='WAIT_OWNER'&&!record.owner_notification_attempted) {
        transport.save(record,record.state,{owner_notification_attempted:true});
        try {await api.sendTelegramNotification('⏸ <b>Требуется решение владельца</b>\n\n'+api.escapeHtml(record.decision.question),0,{inline_keyboard:[[{text:'Ответить '+comp.name,callback_data:'cb_reply_prompt_'+projectKey}]]});}
        catch {transport.save(record,record.state,{owner_notification_uncertain:true});}
      }
      return record;
    },conn);},
    ownerReply(projectKey,text,options={}){return session(projectKey,({transport})=>{const current=transport.current();if(!current?.context_snapshot)throw new Error('OWNER_REPLY_CONTEXT_UNVERIFIED');return transport.dispatch(current.context_snapshot,text,{ownerReply:true,expectedEpoch:options.expectedEpoch,operationId:options.operationId});});}
  };
}
