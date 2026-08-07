#!/usr/bin/env node
'use strict';
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=path.resolve(process.argv[2]||'.');
const failures=[];const passes=[];
function check(id,ok,details){(ok?passes:failures).push({id,details});}
function text(rel){return fs.readFileSync(path.join(root,rel),'utf8');}
function json(rel){return JSON.parse(text(rel));}
const expected='1.2.8';
try{const v=json('VERSION.json'),e=json('ECOSYSTEM_VERSION.json');check('KF-014',v.package_version===expected&&v.runtime_version===expected&&v.playbook_version===expected&&v.companion_version===expected&&e.ecosystem_version===expected&&Object.values(e.components||{}).every(x=>x===expected),'unified version');}catch(e){check('KF-014',false,e.message)}
const ownerFiles=['docs/companion/01_PROJECT_INSTRUCTIONS_v1.2.8.md','docs/companion/SYSTEM_PROMPT_GPT56_COMPANION_v1.2.8.md','docs/companion/02_AGENT_TASK_PACK_CONTRACT_v1.2.8.md','docs/companion/08_PHASE_CONTRACT_AND_PROGRESS_POLICY.md','docs/companion/14_AUTONOMOUS_CONVERGENCE_AND_AUDIT_COVERAGE.md','docs/companion/15_OWNER_OUTPUT_PRESENTATION.md'];
const forbidden=[/repair_batch_limit/i,/repair_batches_used/i,/initial_audits_used/i,/final_audits_used/i,/HARD_STOP_REPAIR_BUDGET/i,/repair\s+batch\s+\d+\s*\/\s*\d+/i,/audit\s+budget/i,/authorize\s+(?:an?\s+)?(?:extra|additional|another)\s+repair/i];
try{const hits=[];for(const f of ownerFiles){const t=text(f);for(const r of forbidden)if(r.test(t))hits.push(`${f}:${r}`)}check('KF-012',hits.length===0,hits.join('; ')||'owner control hidden');}catch(e){check('KF-012',false,e.message)}
try{const t=text('docs/companion/01_PROJECT_INSTRUCTIONS_v1.2.8.md');check('KF-028',['Что происходит','Что уже сделано','Что будет дальше','Нужно ли что-то от владельца'].every(x=>t.includes(x)),'plain sections');check('KF-023',t.includes('AGENTIC_ACTION_PACKET_<project>_<timestamp>.json')&&!t.includes('AGENTIC_ACTION_PACKET_<project>_<timestamp>.zip'),'json action packet');}catch(e){check('KF-028',false,e.message)}
try{const t=text('scripts/windows/companion/Test-CompanionPack-v1.2.8.ps1');check('KF-013',!t.includes("authorize.*repair batch|repair_batch_limit"),'no broad self-matching regex');}catch(e){check('KF-013',false,e.message)}
try{const p=json('tests/regression/KNOWN_FAILURE_PLAYBOOK_v1.2.8.json');check('KF-030',Array.isArray(p.cases)&&p.cases.length>=48,'playbook cases');}catch(e){check('KF-030',false,e.message)}
try{const g=text('lib/global_fix.py');check('KF-003',g.includes('_probe_functional_bash')&&g.includes('GNU bash'),'functional bash probe');check('KF-020',g.indexOf('create_isolated_candidate')<g.indexOf('apply_local_update'),'isolated candidate before mutation');check('KF-021',g.includes('restore_overlay'),'rollback implementation');}catch(e){/* package mode has no lib */}
try{const a=require(path.join(root,'scripts/control-plane/autonomous-convergence.cjs'));const d=a.resolveContinuationPolicy({assuranceMode:'guarded',budget:{repair_batch_limit:1},openFindings:[{lifecycle_status:'open_confirmed',materiality:'product_blocker'}],progressState:{status:'progressing',observations_count:99}});check('KF-012',d.action==='continue_grouped_repair'&&d.limit===null,'legacy counters ignored');}catch(e){check('KF-012',false,e.message)}
try{const k=text('scripts/windows/Test-KnownFailureRegressionPlaybook-v1.2.8.ps1');check('KF-037',/\[object\[\]\]\$FailureArray\s*=\s*\$Failures\.ToArray\(\)/.test(k)&&/\[object\[\]\]\$PassArray\s*=\s*\$Passes\.ToArray\(\)/.test(k),'singleton-safe PowerShell result arrays');}catch(e){check('KF-037',false,e.message)}

try{const n=text('scripts/windows/companion/New-WorkItem.ps1');check('KF-031',n.includes('$PipelineRoot')&&n.includes("operation = 'new_work_item'")&&n.includes('route = $PreferredCommand')&&n.includes('audit_dimensions = $AuditDimensions')&&text('scripts/windows/companion/Start-WorkItemTransaction.ps1').includes('Get-OptionalProperty'),'flow-restoration compatibility');}catch(e){check('KF-031',false,e.message)}
try{const w=text('scripts/control-plane/write-installation-manifest.cjs');check('KF-036',w.includes("'runtime-update'")&&w.includes('defaultNextCommand = null'),'runtime-update manifest mode');}catch(e){check('KF-036',false,e.message)}
try{const a=json('templates/state-profiles/new-project/PHASE_STATUS.json'),b=json('templates/state-profiles/adopt-existing/PHASE_STATUS.json'),c=json('templates/agy-project-base/.agy/PHASE_STATUS.json');check('KF-034',[a,b,c].every(x=>x.framework_version===expected),'state-profile version parity');}catch(e){check('KF-034',false,e.message)}
try{const files=['scripts/bridge/Install-CompanionActionBridge.ps1','scripts/release/Complete-AgenticPipeline-v1.2.8-Deployment.ps1','scripts/release/Create-Companion-Restart-Bootstrap-v1.2.8.ps1','scripts/release/Run-AgenticPipeline-v1.2.8-Upgrade-And-Publish.ps1'];const bad=files.filter(f=>/(?:H10|Athlete Cardio Lab)/i.test(text(f)));check('KF-035',bad.length===0,bad.join('; ')||'generic deployment');}catch(e){check('KF-035',false,e.message)}
try{const p=text('scripts/windows/companion/Publish-CandidateManifest.ps1');check('KF-033',!/@\(\s*\$(?:Candidate|Ambient|Control)\s*\)/.test(p),'Generic List ToArray safety');}catch(e){check('KF-033',false,e.message)}


try{const d=text('scripts/windows/Test-DistributionIntegrity.ps1'),c=text('scripts/windows/companion/Test-CompanionPack-v1.2.8.ps1');const ok=d.includes("ValidateSet('operational', 'strict')")&&d.includes('Distribution advisory warnings')&&d.includes("'-WorkingTreeWhitespacePolicy', 'advisory'")&&c.includes("ValidateSet('strict', 'advisory', 'skip')")&&c.includes(":(exclude,glob)**/*.md");check('KF-040',ok,'operational/advisory gate separation');check('KF-048',ok,'documentation-only whitespace is advisory while non-Markdown remains fail-closed');}catch(e){check('KF-040',false,e.message);check('KF-048',false,e.message)}
try{check('KF-041',fs.existsSync(path.join(root,'scripts/windows/Test-OperationalDeployment.ps1')),'operational deployment smoke present');}catch(e){check('KF-041',false,e.message)}
try{const m=text('scripts/windows/companion/Migrate-ActiveWorkItemToProgressGuard.ps1'),d=text('scripts/windows/Test-DistributionIntegrity.ps1');const t=fs.existsSync(path.join(root,'tests/acceptance/Test-ProgressGuardMigrationCompatibility.ps1'));check('KF-047',m.includes('LEGACY_SHAPE_SAFE_PROGRESS_GUARD_MIGRATION')&&t&&d.includes('progress-guard migration compatibility'),'legacy runtime-state migration compatibility');}catch(e){check('KF-047',false,e.message)}


try {
  const schemaRoot = path.join(root, 'schemas', 'companion');
  if (!fs.existsSync(schemaRoot)) {
    check('KF-046', true, 'schemas are not part of this reduced component package');
  } else {
    const supports = (schema, version) => {
      const node = ((schema || {}).properties || {}).schema_version || {};
      return node.const === version || (Array.isArray(node.enum) && node.enum.includes(version));
    };
    const wi = json('schemas/companion/work-item.schema.json');
    const scope = json('schemas/companion/execution-scope.schema.json');
    const lease = json('schemas/companion/execution-lease.schema.json');
    const firewall = json('schemas/companion/stage-firewall.schema.json');
    const next = json('schemas/companion/next-action.schema.json');
    const manifestStatus = json('schemas/companion/candidate-manifest-status.schema.json');
    const ok = [wi, scope, lease, firewall, next, manifestStatus].every(s => supports(s, '1.1.0'))
      && Object.prototype.hasOwnProperty.call(wi.properties || {}, 'action_packet_id')
      && ['forbidden_paths', 'route', 'discovered_at_utc'].every(k => Object.prototype.hasOwnProperty.call(scope.properties || {}, k))
      && Object.prototype.hasOwnProperty.call(lease.properties || {}, 'route')
      && ['candidate_file_count', 'ambient_file_count'].every(k => Object.prototype.hasOwnProperty.call(manifestStatus.properties || {}, k));
    check('KF-046', ok, 'control-plane writer/schema revision parity');
  }
} catch (e) { check('KF-046', false, e.message); }
const result={ok:failures.length===0,passes,failures};console.log(JSON.stringify(result,null,2));process.exit(failures.length?1:0);
