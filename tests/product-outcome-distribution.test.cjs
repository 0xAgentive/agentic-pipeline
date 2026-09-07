'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(process.env.PIPELINE_REPO_ROOT||path.join(__dirname,'..'));
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const strings=s=>[...s.matchAll(/'([^']+)'/g)].map(m=>m[1].replaceAll('\\','/'));
function array(text,name){const m=text.match(new RegExp('\\$'+name+'\\s*=\\s*@\\(([\\s\\S]*?)\\)'));assert.ok(m,'missing literal '+name);return strings(m[1]);}
const prefix='templates/agy-project-base/';
const products=['scripts/control-plane/product-outcome.cjs','schemas/companion/product-outcome-contract.schema.json','schemas/companion/product-outcome-results.schema.json'];
const activation=['scripts/bridge/companion_action_bridge.py','scripts/bridge/activate_action_packet.py','scripts/bridge/recovery_coordinator.py','scripts/windows/companion/Activate-ActionPacketCore.ps1'];
function plans(){
 const build=read('scripts/windows/Build-AgenticProjectRuntimeOverlay-v1.2.27.ps1');
 const update=read('scripts/windows/Update-AgenticProjectRuntime-v1.2.27.ps1');
 const inventory=JSON.parse(read('config/command-inventory.json')).commands.map(c=>c.workflow.replaceAll('\\','/'));
 const files=new Set(array(build,'Files'));
 for(const filename of fs.readdirSync(path.join(root,prefix,'.agents/workflows')))if(fs.statSync(path.join(root,prefix,'.agents/workflows',filename)).isFile())files.add(prefix+'.agents/workflows/'+filename);
 const direct=array(update,'DirectTargets');
 const map=[...files].flatMap(p=>p.startsWith(prefix)?[p.slice(prefix.length)]:direct.includes(p)?[p]:[]);
 const allow=[...new Set([...array(update,'BaseReplaceTargets'),...inventory,...array(update,'StateTargets')])];
 return {build,update,files,map,allow};
}
test('overlay map equals updater allowlist exactly, including existing metrics helper',()=>{
 const p=plans();assert.equal(p.map.length,new Set(p.map).size,'duplicate deployment target');
 assert.deepEqual([...p.map].sort(),p.allow.sort());
 assert.ok(p.allow.includes('scripts/windows/companion/Get-OperationMetricsSummary.ps1'));
});
test('declared count guards match actual distribution target sets',()=>{
 const p=plans();const builder=Number(p.build.match(/\$DeploymentMap.Count\s+-ne\s+(\d+)/)?.[1]);const updater=Number(p.update.match(/\$AllowedDeploymentTargets.Count\s+-ne\s+(\d+)/)?.[1]);
 assert.equal(builder,p.map.length);assert.equal(updater,p.allow.length);assert.equal(builder,updater);
});
test('all declared overlay source files exist and product runtime dependencies deploy',()=>{
 const p=plans();for(const rel of p.files)assert.ok(fs.statSync(path.join(root,rel)).isFile(),rel);
 for(const rel of [...products,...activation]){assert.ok(p.files.has(prefix+rel),'missing overlay source '+rel);assert.ok(p.allow.includes(rel),'missing updater target '+rel);}
});
test('checker, schemas, publisher and compiler retain canonical template byte parity',()=>{
 for(const rel of [...products,...activation,'scripts/windows/companion/Activate-ActionPacket.ps1','scripts/windows/companion/Publish-CandidateManifest.ps1','scripts/windows/companion/Compile-ResultAuthority.ps1'])assert.deepEqual(fs.readFileSync(path.join(root,rel)),fs.readFileSync(path.join(root,prefix,rel)),rel);
});
test('publisher binds pre-candidate contract and excludes post-candidate scenario results',()=>{
 const names=array(read('scripts/windows/companion/Publish-CandidateManifest.ps1'),'ControlNames');
 assert.equal(names.filter(n=>n==='PRODUCT_OUTCOME_CONTRACT.json').length,1);
 assert.ok(!names.includes('PRODUCT_SCENARIO_RESULTS.json'),'results cannot be frozen before they are produced');
});
test('distribution core gate invokes the product checks through shipped wrapper',()=>{
 const gate='scripts/windows/Test-ProductOutcomeDistribution.ps1';
 assert.ok(read('scripts/windows/Test-DistributionIntegrity.ps1').replaceAll('\\','/').includes(gate));
 const wrapper=read(gate);for(const file of ['product-outcome.test.cjs','product-outcome-distribution.test.cjs'])assert.ok(wrapper.includes(file));
});
test('activation entrypoint project-script dependencies exist in deployable template set',()=>{
 const p=plans();
 for(const rel of ['scripts/windows/companion/Activate-ActionPacket.ps1','scripts/windows/companion/Activate-ActionPacketCore.ps1']){
  const source=read(rel);
  for(const match of source.matchAll(/Join-Path\s+\$Root\s+['"](scripts[\\/][^'"]+)['"]/g)){
   const dependency=match[1].replaceAll('\\','/');
   assert.ok(p.allow.includes(dependency),'entrypoint dependency outside updater: '+dependency);
   assert.ok(p.files.has(prefix+dependency),'entrypoint dependency absent from overlay: '+dependency);
  }
 }
 const adapter=read('scripts/bridge/activate_action_packet.py');
 assert.ok(adapter.includes('companion_action_bridge'),'activation must keep verified importer dependency');
 assert.ok(adapter.includes('Activate-ActionPacketCore.ps1'),'activation must keep real PowerShell consumer dependency');
 for(const rel of activation.filter(name=>name.endsWith('.py'))){
  for(const match of read(rel).matchAll(/Path\(__file__\)\.with_name\(['"]([^'"]+\.py)['"]\)/g)){
   const dependency=path.posix.join(path.posix.dirname(rel),match[1]);
   assert.ok(p.allow.includes(dependency),'adjacent module outside updater: '+dependency);
   assert.ok(p.files.has(prefix+dependency),'adjacent module absent from overlay: '+dependency);
  }
 }
});
