#!/usr/bin/env node
'use strict';
// A verifier invocation, not a receipt-authoring shortcut. Native compiler owns authority.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const record=x=>x!==null&&typeof x==='object'&&!Array.isArray(x);
const hash=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const text=x=>typeof x==='string'&&x.length>0&&!/[\x00-\x1f]/.test(x);
function confined(root,relative){
 if(!text(relative)||relative.normalize('NFC')!==relative||relative.includes('\\')||/[<>:"|?*]/.test(relative)||relative.split('/').some(x=>!x||x==='.'||x==='..'||/[. ]$/.test(x)||/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(x)))throw Error('UNSAFE_EVIDENCE_PATH');
 let current=root;
 for(const segment of relative.split('/')){current=path.join(current,segment);if(fs.lstatSync(current).isSymbolicLink())throw Error('LINK_FORBIDDEN');}
 if(!fs.statSync(current).isFile())throw Error('REGULAR_FILE_REQUIRED');return current;
}
function nativeExecute({file,args,cwd,timeoutMs}){
 return new Promise((resolve,reject)=>cp.execFile(file,args,{cwd,timeout:timeoutMs,maxBuffer:8*1024*1024,windowsHide:true,encoding:'utf8'},(error,stdout,stderr)=>{
  if(error){if(typeof error.code!=='number')return reject(error);return resolve({exitCode:error.code,stdout,stderr});}resolve({exitCode:0,stdout,stderr});
 }));
}
async function observeAuthority({projectRoot,binding,decision,compilerExecutable='pwsh',execute=nativeExecute,intent='completion'}){
 const facts={},errors=[];let observation=null,advancementAllowed=false;
 const fail=reason=>{throw Error(reason)};
 try{
  if(!record(binding)||Object.keys(binding).sort().join(',')!=='context_sha256,epoch,project_id,turn_id'||!text(binding.project_id)||!text(binding.turn_id)||!Number.isSafeInteger(binding.epoch)||binding.epoch<0||!hash(binding.context_sha256))fail('INVALID_BINDING');
  if(!record(decision)||decision.kind!=='completed'||!text(decision.work_item_id)||!Array.isArray(decision.evidence_refs)||!decision.evidence_refs.length||decision.evidence_refs.some(x=>!text(x))||new Set(decision.evidence_refs).size!==decision.evidence_refs.length)fail('COMPLETION_DECISION_REQUIRED');
  const root=fs.realpathSync(projectRoot),snapshots=new Map();
  const read=(name)=>{const b=fs.readFileSync(confined(root,name));snapshots.set(name,sha(b));return JSON.parse(b.toString('utf8').replace(/^\uFEFF/,''));};
  const work=read('.agy/WORK_ITEM.json'),identity=read('.agy/ACTION_BRIDGE_CAPABILITY.json'),receipt=read('.agy/VERIFICATION_RECEIPT.json'),candidate=read('.agy/CANDIDATE_MANIFEST.json');
  const acceptedIds=[identity.project_id,...(Array.isArray(identity.aliases)?identity.aliases:[])];
  if(!acceptedIds.includes(binding.project_id))fail('PROJECT_IDENTITY_MISMATCH');
  if(work.work_item_id!==decision.work_item_id||work.owner_approved!==true||!Number.isSafeInteger(work.goal_epoch)||work.goal_epoch<1)fail('CURRENT_WORK_IDENTITY_MISMATCH');
  const head=cp.execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8',timeout:10000}).trim();
  if(receipt.work_item_id!==work.work_item_id||receipt.goal_epoch!==work.goal_epoch||receipt.head!==head||receipt.candidate_manifest_sha256!==snapshots.get('.agy/CANDIDATE_MANIFEST.json'))fail('RECEIPT_IDENTITY_MISMATCH');
  if(!Array.isArray(receipt.tests)||!receipt.tests.length||!receipt.tests.some(x=>x.required===true)||!Array.isArray(receipt.evidence_artifacts))fail('REQUIRED_EVIDENCE_ABSENT');
  const refs=new Set(),runs=new Set();
  for(const run of receipt.tests){
   if(!record(run)||!text(run.run_id)||runs.has(run.run_id)||typeof run.required!=='boolean'||!Number.isInteger(run.exit_code))fail('TEST_RECEIPT_INVALID');runs.add(run.run_id);
   if(run.required&&run.exit_code!==0)fail('REQUIRED_TEST_FAILED');
   if(!hash(run.evidence_sha256)||!Number.isSafeInteger(run.evidence_size_bytes)||run.evidence_size_bytes<0||!run.evidence_path?.startsWith('.agy/verification/'))fail('TEST_WITNESS_INVALID');
   const b=fs.readFileSync(confined(root,run.evidence_path));if(sha(b)!==run.evidence_sha256||b.length!==run.evidence_size_bytes)fail('TEST_WITNESS_CHANGED');snapshots.set(run.evidence_path,sha(b));refs.add(run.evidence_path);
  }
  for(const name of receipt.evidence_artifacts){const b=fs.readFileSync(confined(root,name));snapshots.set(name,sha(b));}
  if(decision.evidence_refs.some(x=>!receipt.evidence_artifacts.includes(x)&&!refs.has(x)))fail('UNPROVEN_COMPLETION_REFERENCE');
  // Current compiler validates all native contracts; observer also detects candidate mutation
  // across the call rather than promoting a stale successful child process result.
  for(const item of [...(candidate.candidate_files||[]),...(candidate.control_plane_files||[])]){
   if(!record(item)||!text(item.path)||!hash(item.sha256))fail('CANDIDATE_REFERENCE_INVALID');
   const b=fs.readFileSync(confined(root,item.path));if(sha(b)!==item.sha256)fail('CANDIDATE_FILE_CHANGED');snapshots.set(item.path,sha(b));
  }
  const tool='scripts/windows/companion/Compile-ResultAuthority.ps1',toolPath=confined(root,tool);snapshots.set(tool,sha(fs.readFileSync(toolPath)));
  const args=['-NoLogo','-NoProfile','-NonInteractive','-File',toolPath,'-ProjectRoot',root,'-VerificationReceiptPath',path.join(root,'.agy/VERIFICATION_RECEIPT.json'),'-TimeoutSeconds','120'];
  let reply;try{reply=await execute({file:compilerExecutable,args,cwd:root,timeoutMs:140000});}catch(error){fail(error?.code==='ENOENT'?'NATIVE_COMPILER_UNAVAILABLE':'NATIVE_COMPILER_UNCERTAIN');}
  if(!record(reply)||reply.exitCode!==0||typeof reply.stdout!=='string')fail('NATIVE_COMPILER_REJECTED');
  let payload;try{payload=JSON.parse(reply.stdout.replace(/^\uFEFF/,''));}catch{fail('NATIVE_COMPILER_OUTPUT_INVALID');}
  const run=payload?.run_result,closure=payload?.closure,next=payload?.next_action,provenance=run?.verification_receipt;
  if(!record(run)||!record(closure)||!record(next)||!record(provenance)||run.work_item_id!==work.work_item_id||closure.work_item_id!==work.work_item_id||next.work_item_id!==work.work_item_id||run.head!==head||provenance.work_item_id!==work.work_item_id||provenance.head!==head||provenance.path!=='.agy/VERIFICATION_RECEIPT.json'||provenance.sha256!==snapshots.get('.agy/VERIFICATION_RECEIPT.json')||provenance.candidate_manifest_sha256!==receipt.candidate_manifest_sha256)fail('NATIVE_COMPILER_IDENTITY_MISMATCH');
  const accepted=run.acceptance_status==='accepted'&&closure.acceptance_status==='accepted'&&run.verification_status==='passed'&&closure.verification_status==='passed';
  const debt=run.acceptance_status==='completed_with_verification_debt'&&closure.acceptance_status==='completed_with_verification_debt'&&closure.next_owner_goal_allowed===true;
  if(run.implementation_status!=='completed'||closure.implementation_status!=='completed'||run.hard_stop!==false||!(accepted||(intent==='advance'&&debt)))fail('WORK_COMPLETION_NOT_ACCEPTED');
  if(!Array.isArray(run.product_blockers)||run.product_blockers.length||!Array.isArray(run.verification_blockers)||(accepted&&run.verification_blockers.length))fail('MATERIAL_BLOCKERS_REMAIN');
  advancementAllowed=closure.next_owner_goal_allowed===true&&(accepted||debt)&&next.owner_decision_required===false&&next.hard_stop!==true&&next.auto_continue===false&&!next.route;
  if(!Array.isArray(run.evidence_artifacts)||decision.evidence_refs.some(x=>!run.evidence_artifacts.includes(x)))fail('COMPILER_EVIDENCE_MISMATCH');
  if(cp.execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8',timeout:10000}).trim()!==head)fail('HEAD_CHANGED_DURING_OBSERVATION');
  for(const[name,digest]of snapshots)if(sha(fs.readFileSync(confined(root,name)))!==digest)fail('INPUT_CHANGED_DURING_OBSERVATION');
  const observationId=crypto.randomUUID(),directory=path.join(root,'.agy/.runtime/completion-observations');for(const d of [path.join(root,'.agy'),path.join(root,'.agy/.runtime'),directory]){if(fs.existsSync(d)){if(fs.lstatSync(d).isSymbolicLink()||!fs.statSync(d).isDirectory())fail('OBSERVATION_DIRECTORY_UNSAFE');}else fs.mkdirSync(d);}
  const rel='.agy/.runtime/completion-observations/'+observationId+'.json';
  observation={schema_version:'1.0.0',observation_id:observationId,binding:{...binding},work_item_id:work.work_item_id,goal_epoch:work.goal_epoch,head,candidate_manifest_sha256:receipt.candidate_manifest_sha256,receipt_sha256:provenance.sha256,compiler_sha256:snapshots.get(tool),compiler_output_sha256:sha(Buffer.from(reply.stdout)),observed_at_utc:new Date().toISOString(),scope:accepted?'work_item_acceptance_revalidated_by_native_compiler':'next_owner_goal_allowed_with_verification_debt',release:'not_evaluated',advancement_allowed:advancementAllowed,witnesses:[...snapshots].filter(([p])=>!p.includes('CAPABILITY')).map(([p,h])=>({path:p,sha256:h}))};
  // Public observation never contains credentials, child stdout or rewritten original receipts.
  const tmp=path.join(directory,'.'+observationId+'.tmp');fs.writeFileSync(tmp,JSON.stringify(observation,null,2)+'\n',{flag:'wx',mode:0o600});fs.renameSync(tmp,path.join(root,rel));
  facts.execution_receipt={...binding,work_item_id:work.work_item_id,outcome:'succeeded',receipt_id:rel};
  if(accepted)facts.acceptance_receipt={...binding,work_item_id:work.work_item_id,outcome:'passed',receipt_id:rel,evidence_refs:[...decision.evidence_refs]};
 }catch(error){errors.push(/^[A-Z][A-Z0-9_]+$/.test(error.message)?error.message:'EVIDENCE_UNAVAILABLE_OR_UNSAFE');}
 return{ok:errors.length===0,facts:errors.length?{}:facts,errors,observation:errors.length?null:observation,release_ready:false,advancement_allowed:errors.length?false:advancementAllowed};
}
async function collectCompletionEvidence(options){return observeAuthority({...options,intent:'completion'});}
async function collectExecutionAdvance(options){
 try{
  const root=fs.realpathSync(options.projectRoot),work=JSON.parse(fs.readFileSync(confined(root,'.agy/WORK_ITEM.json'),'utf8').replace(/^\uFEFF/,'')),receipt=JSON.parse(fs.readFileSync(confined(root,'.agy/VERIFICATION_RECEIPT.json'),'utf8').replace(/^\uFEFF/,''));
  const evidenceRefs=[...new Set((receipt.tests||[]).filter(x=>x.required===true).map(x=>x.evidence_path))];
  return observeAuthority({...options,decision:{kind:'completed',work_item_id:work.work_item_id,evidence_refs:evidenceRefs},intent:'advance'});
 }catch{return {ok:false,facts:{},errors:['ADVANCEMENT_EVIDENCE_UNAVAILABLE'],observation:null,release_ready:false,advancement_allowed:false};}
}
module.exports={collectCompletionEvidence,collectExecutionAdvance,confined};
