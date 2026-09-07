#!/usr/bin/env node
'use strict';
// Product evidence join. This does not run tests, author acceptance or publish releases.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const own=(v,keys)=>object(v)&&Object.keys(v).every(k=>keys.includes(k));
const identKeys=['work_item_id','goal_epoch','head','candidate_manifest_sha256'];
function identityValid(v){return object(v)&&typeof v.work_item_id==='string'&&v.work_item_id.length>0&&Number.isSafeInteger(v.goal_epoch)&&v.goal_epoch>=1&&/^[a-f0-9]{40}$/.test(v.head||'')&&/^[a-f0-9]{64}$/.test(v.candidate_manifest_sha256||'');}
function confined(root,name){
 if(typeof name!=='string'||!name||name.normalize('NFC')!==name||name.includes('\\')||/[\x00-\x1f<>:"|?*]/.test(name)||path.posix.isAbsolute(name)||name.split('/').some(p=>!p||p==='.'||p==='..'||/[. ]$/.test(p)||/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(p)))throw Error('UNSAFE_PATH');
 let p=path.resolve(root);
 for(const part of name.split('/')){p=path.join(p,part);if(fs.lstatSync(p).isSymbolicLink())throw Error('LINK_FORBIDDEN');}
 if(!fs.statSync(p).isFile())throw Error('NOT_REGULAR_FILE');return p;
}
function verifyProductOutcome({root,identity,contract,results,receipt}){
 const errors=[],debt=[];
 const add=s=>errors.push(s);
 if(!identityValid(identity))add('CURRENT_IDENTITY_INVALID');
 for(const [label,v,keys] of [['CONTRACT',contract,['work_item_id','goal_epoch','head','schema_version','scenarios','artifacts']],['RESULTS',results,[...identKeys,'schema_version','scenarios']]]){
  if(!own(v,keys)||v.schema_version!=='1.0.0'||!identityValid({...v,candidate_manifest_sha256:label==='CONTRACT'?identity?.candidate_manifest_sha256:v.candidate_manifest_sha256})){add(label+'_INVALID');continue;}
  for(const k of (label==='CONTRACT'?identKeys.filter(k=>k!=='candidate_manifest_sha256'):identKeys))if(v[k]!==identity?.[k])add(label+'_STALE_'+k);
 }
 if(!object(receipt)||!Array.isArray(receipt.tests))add('RECEIPT_TESTS_REQUIRED');
 if(errors.length)return report();
 if(!Array.isArray(contract.scenarios)||!contract.scenarios.length||!contract.scenarios.some(s=>s.required===true))add('REQUIRED_SCENARIOS_EMPTY');
 if(!Array.isArray(results.scenarios))add('SCENARIO_RESULTS_INVALID');
 if(!Array.isArray(contract.artifacts)||!contract.artifacts.length)add('PRODUCT_ARTIFACTS_EMPTY');
 if(errors.length)return report();
 const expected=new Map(),actual=new Map(),runIds=new Set(),paths=new Set();
 for(const s of contract.scenarios){
  if(!own(s,['id','required'])||typeof s.id!=='string'||!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s.id)||typeof s.required!=='boolean'){add('SCENARIO_CONTRACT_INVALID');continue;}
  if(expected.has(s.id))add('DUPLICATE_EXPECTED_SCENARIO:'+s.id);expected.set(s.id,s);
 }
 for(const s of results.scenarios){
  if(!own(s,['id','status','run_id','exit_code','evidence'])||typeof s.id!=='string'){add('SCENARIO_RESULT_INVALID');continue;}
  if(!expected.has(s.id))add('UNEXPECTED_SCENARIO:'+s.id);
  if(actual.has(s.id))add('DUPLICATE_RESULT:'+s.id);actual.set(s.id,s);
 }
 function file(ref,prefix){
  if(!own(ref,['path','sha256'])||typeof ref.path!=='string'||!/^[a-f0-9]{64}$/.test(ref.sha256||'')){add('FILE_REFERENCE_INVALID');return;}
  if(prefix&&!ref.path.startsWith(prefix)){add('EVIDENCE_OUTSIDE_VERIFICATION');return;}
  if(/(^|\/)(\.env(?:\.|$)|[^/]*(?:capability|credential|password|secret|token|private[-_]?key)[^/]*)/i.test(ref.path)){add('SENSITIVE_REFERENCE');return;}
  try{const p=confined(root,ref.path);if(digest(fs.readFileSync(p))!==ref.sha256)add('FILE_HASH_MISMATCH:'+ref.path);}catch(e){add('FILE_UNAVAILABLE_OR_UNSAFE:'+ref.path);}
 }
 for(const [id,s] of expected){
  const got=actual.get(id);
  if(!got||got.status!=='passed') {if(s.required)add('SCENARIO_NOT_PASSED:'+id);else debt.push(id);continue;}
  if(!Number.isInteger(got.exit_code)||got.exit_code!==0)add('EXIT_NOT_SUCCESS:'+id);
  if(typeof got.run_id!=='string'||!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(got.run_id)||runIds.has(got.run_id))add('RUN_ID_INVALID_OR_REUSED:'+id);
  runIds.add(got.run_id);
  const runs=receipt.tests.filter(t=>t.run_id===got.run_id);
  if(runs.length!==1||runs[0].exit_code!==0||(s.required&&runs[0].required!==true))add('RECEIPT_RUN_MISMATCH:'+id);
  if(!Array.isArray(got.evidence)||!got.evidence.length)add('SCENARIO_EVIDENCE_EMPTY:'+id);
  else got.evidence.forEach(r=>{if(!runs.some(t=>t.evidence_path===r.path&&t.evidence_sha256===r.sha256))add('RECEIPT_EVIDENCE_MISMATCH:'+id);file(r,'.agy/verification/');});
 }
 for(const ref of contract.artifacts){const key=typeof ref?.path==='string'?ref.path.toLowerCase():'';if(paths.has(key))add('ARTIFACT_PATH_COLLISION');paths.add(key);file(ref);}
 return report();
 function report(){return {schema_version:'1.0.0',ok:errors.length===0,product_ready:false,scenario_evidence_verified:errors.length===0,evidence_scope:'additional_scenario_check_only',semantic_observation_review:'required',identity,optional_debt:debt,errors};}
}
function readJson(file){return JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));}
function verifyProject(root,receiptPath='.agy/VERIFICATION_RECEIPT.json'){
 root=fs.realpathSync(root);
 const work=readJson(confined(root,'.agy/WORK_ITEM.json'));
 if(path.isAbsolute(receiptPath))receiptPath=path.relative(root,receiptPath).split(path.sep).join('/');
 if(!receiptPath.startsWith('.agy/'))throw Error('RECEIPT_OUTSIDE_CONTROL_PLANE');
 const receiptBytes=fs.readFileSync(confined(root,receiptPath));
 const receipt=JSON.parse(receiptBytes.toString('utf8').replace(/^\uFEFF/,''));
 const candidateBytes=fs.readFileSync(confined(root,'.agy/CANDIDATE_MANIFEST.json'));
 const head=cp.execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8',timeout:10000}).trim();
 const identity={work_item_id:work.work_item_id,goal_epoch:work.goal_epoch,head,candidate_manifest_sha256:digest(candidateBytes)};
 for(const k of identKeys)if(receipt[k]!==identity[k])throw Error('RECEIPT_IDENTITY_MISMATCH');
 const candidate=JSON.parse(candidateBytes.toString('utf8').replace(/^\uFEFF/,''));
 const contractPath='.agy/PRODUCT_OUTCOME_CONTRACT.json',resultsPath='.agy/PRODUCT_SCENARIO_RESULTS.json';
 const refs=(candidate.control_plane_files||[]).filter(r=>r.path===contractPath);
 if(refs.length!==1||digest(fs.readFileSync(confined(root,contractPath)))!==refs[0].sha256)throw Error('OUTCOME_CONTRACT_NOT_BOUND');
 if(!Array.isArray(receipt.evidence_artifacts)||!receipt.evidence_artifacts.includes(resultsPath))throw Error('SCENARIO_RESULTS_NOT_IN_RECEIPT');
 const result=verifyProductOutcome({root,identity,receipt,contract:readJson(confined(root,contractPath)),results:readJson(confined(root,resultsPath))});
 return {...result,authority_revalidation:'owned_by_Compile-ResultAuthority.ps1'};
}
if(require.main===module){try{const args=process.argv.slice(2);if(![2,4].includes(args.length)||args[0]!=='--project-root'||(args.length===4&&args[2]!=='--receipt-path'))throw Error('Usage: product-outcome.cjs --project-root PATH [--receipt-path PATH]');const r=verifyProject(args[1],args[3]);console.log(JSON.stringify(r,null,2));process.exitCode=r.ok?0:1;}catch(e){console.log(JSON.stringify({ok:false,product_ready:false,errors:[e.message]}));process.exitCode=1;}}
module.exports={verifyProductOutcome,verifyProject,confined};
