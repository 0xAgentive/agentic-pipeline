#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const cp = require('child_process');

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = stable(value[key]);
    return out;
  }
  return value;
}
function sha256(value) {
  const data = Buffer.isBuffer(value) ? value : Buffer.from(typeof value === 'string' ? value : JSON.stringify(stable(value)));
  return crypto.createHash('sha256').update(data).digest('hex');
}
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function normalize(p) { return path.resolve(p).replace(/\\/g, '/').replace(/\/$/, '').toLowerCase(); }
function git(cwd, args) {
  const r = cp.spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
  return { code: r.status ?? 1, stdout: (r.stdout || '').trim(), stderr: (r.stderr || '').trim() };
}
function unique(xs) { return [...new Set(xs)]; }
function result(ok, code, details = {}) { return { ok, code, ...details }; }

function validateBriefContinuity({ previous, current }) {
  const errors = [];
  if (!previous || !current) errors.push('BRIEF_MISSING');
  if (previous && current) {
    if (String(previous.work_item_id) !== String(current.work_item_id)) errors.push('WORK_ITEM_ID_CHANGED');
    if (Number(previous.goal_epoch) !== Number(current.goal_epoch)) errors.push('GOAL_EPOCH_CHANGED');
    if (String(previous.brief_fingerprint || previous.owner_goal_fingerprint || '') !== String(current.brief_fingerprint || current.owner_goal_fingerprint || '')) errors.push('BRIEF_FINGERPRINT_CHANGED');
    if (String(previous.goal || '') !== String(current.goal || '')) errors.push('OWNER_GOAL_CHANGED');
    if (Number(current.brief_revision || 1) !== Number(previous.brief_revision || 1)) errors.push('BRIEF_REVISION_CHANGED');
  }
  return result(errors.length === 0, errors.length ? 'IMMUTABLE_BRIEF_VIOLATION' : 'IMMUTABLE_BRIEF_VALID', { errors });
}

function validateExecutionLease({ workItem, scope, lease, live }) {
  const errors = [];
  if (!workItem || workItem.owner_approved !== true) errors.push('WORK_ITEM_NOT_OWNER_APPROVED');
  if (!scope || scope.status !== 'exact') errors.push('EXECUTION_SCOPE_NOT_EXACT');
  if (!lease || lease.status !== 'active') errors.push('EXECUTION_LEASE_NOT_ACTIVE');
  if (workItem && scope && workItem.work_item_id !== scope.work_item_id) errors.push('WORK_ITEM_SCOPE_MISMATCH');
  if (workItem && lease && workItem.work_item_id !== lease.work_item_id) errors.push('WORK_ITEM_LEASE_MISMATCH');
  if (workItem && lease && Number(workItem.goal_epoch) !== Number(lease.goal_epoch)) errors.push('GOAL_EPOCH_MISMATCH');
  if (workItem && lease && sha256(workItem.goal || '') !== lease.owner_goal_sha256) errors.push('OWNER_GOAL_FINGERPRINT_MISMATCH');
  if (scope && lease && sha256(scope) !== lease.execution_scope_sha256) errors.push('EXECUTION_SCOPE_FINGERPRINT_MISMATCH');
  if (scope && lease && normalize(scope.project_root) !== normalize(lease.project_root)) errors.push('PROJECT_ROOT_MISMATCH');
  if (live && lease) {
    if (normalize(live.worktree_root) !== normalize(lease.worktree_root)) errors.push('WORKTREE_ROOT_MISMATCH');
    if (String(live.branch) !== String(lease.branch)) errors.push('BRANCH_MISMATCH');
    if (!lease.first_write_started && String(live.head) !== String(lease.baseline_head)) errors.push('BASELINE_HEAD_MISMATCH');
  }
  if (!Array.isArray(lease?.allowed_paths) || lease.allowed_paths.length === 0) errors.push('LEASE_ALLOWED_PATHS_EMPTY');
  return result(errors.length === 0, errors.length ? 'EXECUTION_LEASE_INVALID' : 'EXECUTION_LEASE_VALID', { errors });
}

function validateAuditCoverage({ workItem, matrix }) {
  const errors = [];
  const acceptance = Array.isArray(workItem?.acceptance) ? workItem.acceptance : [];
  const rows = Array.isArray(matrix?.acceptance_coverage) ? matrix.acceptance_coverage : [];
  const dimensions = workItem?.audit_dimensions && typeof workItem.audit_dimensions === 'object' ? workItem.audit_dimensions : {};
  const dimensionRows = Array.isArray(matrix?.dimension_coverage) ? matrix.dimension_coverage : [];
  const ids = [...rows, ...dimensionRows].map(r => r.coverage_id);
  if (unique(ids).length !== ids.length) errors.push('DUPLICATE_COVERAGE_ID');
  const indexes = rows.map(r => Number(r.acceptance_index));
  for (let i = 0; i < acceptance.length; i++) if (!indexes.includes(i)) errors.push(`ACCEPTANCE_NOT_COVERED:${i}`);
  const dimensionKeys = new Set(dimensionRows.map(r => `${r.dimension}::${r.item_id}`));
  for (const [dimension, items] of Object.entries(dimensions)) {
    for (const item of Array.isArray(items) ? items : []) {
      if (!dimensionKeys.has(`${dimension}::${item}`)) errors.push(`DIMENSION_NOT_COVERED:${dimension}:${item}`);
    }
  }
  for (const row of [...rows, ...dimensionRows]) {
    if (!Array.isArray(row.surfaces) || !row.surfaces.length) errors.push(`SURFACES_EMPTY:${row.coverage_id}`);
    if (!Array.isArray(row.evidence_required) || !row.evidence_required.length) errors.push(`EVIDENCE_EMPTY:${row.coverage_id}`);
    if (!Array.isArray(row.checks) || !row.checks.length) errors.push(`CHECKS_EMPTY:${row.coverage_id}`);
    if (!['covered','finding_open','blocked','not_applicable'].includes(row.status) && matrix?.status === 'complete') errors.push(`INCOMPLETE_COVERAGE:${row.coverage_id}`);
  }
  if (matrix?.audit_cycle === 'initial_comprehensive' && matrix?.status !== 'complete') errors.push('INITIAL_AUDIT_NOT_COMPLETE');
  return result(errors.length === 0, errors.length ? 'AUDIT_COVERAGE_INVALID' : 'AUDIT_COVERAGE_VALID', { errors });
}
function classifyLateFinding({ finding, coverageMatrix }) {
  const initialComplete = coverageMatrix?.audit_cycle === 'initial_comprehensive' && coverageMatrix?.status === 'complete';
  const coverageIds = new Set((coverageMatrix?.acceptance_coverage || []).map(x => x.coverage_id));
  const covered = finding.coverage_id && coverageIds.has(finding.coverage_id);
  if (initialComplete && !covered && finding.materiality === 'product_blocker') {
    return { ...finding, origin: 'audit_coverage_miss' };
  }
  return { ...finding, origin: finding.origin || 'initial_audit' };
}

function resolveContinuationPolicy({ assuranceMode, budget, openFindings = [], progressState = {} }) {
  // Legacy budget-shaped input is accepted only for backward compatibility.
  // Routing is based on material progress and real owner decisions.
  const product = openFindings.filter(f => f.lifecycle_status === 'open_confirmed' && f.materiality === 'product_blocker');
  const verification = openFindings.filter(f => f.lifecycle_status === 'open_confirmed' && ['verification_blocker','release_blocker'].includes(f.materiality));
  const stalled = progressState.status === 'stalled' || Number(progressState.consecutive_no_progress || 0) >= 2 || Number(progressState.same_failure_count || 0) >= 2;
  if (progressState.owner_decision_required === true) return { status: 'owner_decision', used: Number(progressState.observations_count || progressState.iteration_count || 0), limit: null, action: 'human_decision_required' };
  if (stalled) return { status: 'stalled', used: Number(progressState.observations_count || progressState.iteration_count || 0), limit: null, action: 'hard_stop_no_progress' };
  if (product.length) return { status: 'available', used: Number(progressState.observations_count || progressState.iteration_count || 0), limit: null, action: 'continue_grouped_repair' };
  if (verification.length) return { status: 'available', used: Number(progressState.observations_count || progressState.iteration_count || 0), limit: null, action: 'continue_verification_or_close_debt' };
  return { status: 'available', used: Number(progressState.observations_count || progressState.iteration_count || 0), limit: null, action: 'close_accepted' };
}

function validateProtectedReviewer(a, expected = {}) {
  const errors = [];
  if (!a) return result(false, 'REVIEWER_ATTESTATION_MISSING', { errors: ['MISSING'] });
  if (a.read_only !== true) errors.push('REVIEWER_NOT_READ_ONLY');
  if (!a.target_head || String(a.target_head).length < 7) errors.push('TARGET_HEAD_MISSING');
  if (a.implementation_context_id === a.reviewer_context_id) errors.push('SAME_CONTEXT');
  if (normalize(a.implementation_root) === normalize(a.reviewer_root)) errors.push('SAME_MUTABLE_ROOT');
  if (a.predicate_origin === 'implementation_context') errors.push('SELF_AUTHORED_PREDICATES');
  if (a.reviewer_authored_implementation === true) errors.push('REVIEWER_AUTHORED_IMPLEMENTATION');
  if (a.reviewer_authored_artifact_generator === true) errors.push('REVIEWER_AUTHORED_ARTIFACT_GENERATOR');
  if (a.reviewer_authored_predicates === true) errors.push('REVIEWER_AUTHORED_PREDICATES');
  if (!/^[0-9a-f]{64}$/.test(String(a.artifact_manifest_sha256 || ''))) errors.push('ARTIFACT_MANIFEST_IDENTITY_INVALID');
  if (expected.target_head && String(a.target_head) !== String(expected.target_head)) errors.push('AUDIT_TARGET_HEAD_MISMATCH');
  if (expected.artifact_manifest_sha256 && String(a.artifact_manifest_sha256) !== String(expected.artifact_manifest_sha256)) errors.push('AUDIT_ARTIFACT_MANIFEST_MISMATCH');
  if (a.independence_status !== 'independent') errors.push('INDEPENDENCE_NOT_PROVEN');
  return result(errors.length === 0, errors.length ? 'REVIEWER_NOT_INDEPENDENT' : 'REVIEWER_INDEPENDENT', { errors });
}

function globToRegex(glob) {
  const escaped = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '§§').replace(/\*/g, '[^/]*').replace(/§§/g, '.*');
  return new RegExp(`^${escaped}$`, 'i');
}
function validateStageFirewall({ firewall, changedPaths = [] }) {
  if (!firewall || firewall.status !== 'active' || firewall.stage_profile !== 'protocol_freeze') {
    return result(true, 'STAGE_FIREWALL_NOT_APPLICABLE', { blocked_paths: [] });
  }
  const patterns = (firewall.protected_path_patterns || []).map(globToRegex);
  const blocked = changedPaths.map(p => p.replace(/\\/g,'/')).filter(p => patterns.some(r => r.test(p)));
  if (blocked.length && !firewall.algorithm_repair_authorized) {
    return result(false, 'SCIENTIFIC_STAGE_FIREWALL_BLOCKED', { blocked_paths: blocked });
  }
  return result(true, 'SCIENTIFIC_STAGE_FIREWALL_VALID', { blocked_paths: [] });
}

function compileClosure({ workItem, findings = [], verificationReceipt, auditResult, reviewerAttestation, budget, progressState = {} }) {
  const open = findings.filter(f => f.lifecycle_status === 'open_confirmed');
  const product = open.filter(f => f.materiality === 'product_blocker');
  const verification = open.filter(f => f.materiality === 'verification_blocker');
  const release = open.filter(f => f.materiality === 'release_blocker');
  const requiredRuns = (verificationReceipt?.tests || []).filter(t => t.required !== false);
  const verificationPassed = requiredRuns.length > 0 && requiredRuns.every(t => Number(t.exit_code) === 0);
  const assurance = workItem?.assurance_mode || 'flow';
  const review = validateProtectedReviewer(reviewerAttestation);
  const auditStatus = assurance === 'flow' ? 'not_required' : (review.ok && auditResult?.status === 'passed' ? 'passed' : 'unavailable');
  const stalled = progressState.status === 'stalled' || Number(progressState.consecutive_no_progress || 0) >= 2 || Number(progressState.same_failure_count || 0) >= 2;
  let acceptanceStatus, implementationStatus, verificationStatus, releaseStatus, nextAllowed, nextWorkflow, reason;
  if (product.length && !stalled) {
    acceptanceStatus='not_evaluated'; implementationStatus='in_progress'; verificationStatus=verificationPassed?'partial':'not_run'; releaseStatus='blocked'; nextAllowed=false; nextWorkflow='/fixcritical'; reason='repair_continues_automatically';
  } else if (product.length) {
    acceptanceStatus='blocked'; implementationStatus='blocked'; verificationStatus=verificationPassed?'partial':'failed'; releaseStatus='blocked'; nextAllowed=false; nextWorkflow=null; reason='repeated_no_progress_with_product_blocker';
  } else if (!verificationPassed) {
    acceptanceStatus='not_evaluated'; implementationStatus='completed'; verificationStatus='blocked'; releaseStatus='blocked'; nextAllowed=false; nextWorkflow='/auditphase'; reason='required_verification_missing_or_failed';
  } else if (assurance !== 'flow' && auditStatus !== 'passed') {
    acceptanceStatus='completed_with_verification_debt'; implementationStatus='completed'; verificationStatus='partial'; releaseStatus='blocked'; nextAllowed=true; nextWorkflow=null; reason='protected_audit_unavailable';
  } else if (verification.length || release.length) {
    acceptanceStatus='completed_with_verification_debt'; implementationStatus='completed'; verificationStatus='partial'; releaseStatus='blocked'; nextAllowed=true; nextWorkflow=null; reason='verification_or_release_debt';
  } else {
    acceptanceStatus='accepted'; implementationStatus='completed'; verificationStatus='passed'; releaseStatus=assurance==='release'?'open':'not_applicable'; nextAllowed=true; nextWorkflow=null; reason='all_material_gates_passed';
  }
  return {
    schema_version:'1.0.0', work_item_id:workItem?.work_item_id || 'unknown', implementation_status:implementationStatus,
    verification_status:verificationStatus, audit_status:auditStatus, acceptance_status:acceptanceStatus, release_status:releaseStatus,
    next_owner_goal_allowed:nextAllowed, next_workflow:nextWorkflow, closure_reason:reason, open_finding_ids:open.map(f=>f.finding_id),
    progress_observations:Number(progressState.observations_count || progressState.iteration_count || 0),
    generated_at_utc:new Date().toISOString()
  };
}
function liveGit(root) {
  const gitRoot = git(root, ['rev-parse','--show-toplevel']);
  const branch = git(root, ['rev-parse','--abbrev-ref','HEAD']);
  const head = git(root, ['rev-parse','HEAD']);
  const status = git(root, ['status','--porcelain=v1']);
  if ([gitRoot, branch, head, status].some(x => x.code !== 0)) throw new Error('Unable to read live Git facts');
  return { worktree_root: gitRoot.stdout, branch: branch.stdout, head: head.stdout, git_state: status.stdout ? 'dirty' : 'clean' };
}

function validateProject(projectRoot) {
  const agy = path.join(projectRoot, '.agy');
  const workItem = readJson(path.join(agy,'WORK_ITEM.json'));
  const scope = readJson(path.join(agy,'EXECUTION_SCOPE.json'));
  const lease = readJson(path.join(agy,'EXECUTION_LEASE.json'));
  const live = liveGit(projectRoot);
  return validateExecutionLease({workItem,scope,lease,live});
}

function parseArgs(argv) {
  const args={};
  for(let i=0;i<argv.length;i++) if(argv[i].startsWith('--')) { const k=argv[i].slice(2); args[k]=argv[i+1] && !argv[i+1].startsWith('--') ? argv[++i] : true; }
  return args;
}

function selfTest() {
  const workItem={work_item_id:'wi-001',goal_epoch:1,goal:'Goal',assurance_mode:'guarded',owner_approved:true,acceptance:['A','B']};
  const scope={schema_version:'1.0.0',work_item_id:'wi-001',status:'exact',project_root:'/tmp/p',git_head:'abc',allowed_paths:['src'],forbidden_domains:[],generated_at_utc:'x'};
  const lease={status:'active',work_item_id:'wi-001',goal_epoch:1,project_root:'/tmp/p',worktree_root:'/tmp/p',branch:'main',baseline_head:'abc',owner_goal_sha256:sha256('Goal'),execution_scope_sha256:sha256(scope),allowed_paths:['src'],first_write_started:false};
  const checks=[];
  checks.push(validateBriefContinuity({previous:{...workItem,brief_revision:1,brief_fingerprint:sha256('Goal')},current:{...workItem,brief_revision:1,brief_fingerprint:sha256('Goal')}}).ok);
  checks.push(!validateBriefContinuity({previous:{...workItem,brief_revision:1,brief_fingerprint:sha256('Goal')},current:{...workItem,goal:'Changed',brief_revision:2,brief_fingerprint:sha256('Changed')}}).ok);
  checks.push(validateExecutionLease({workItem,scope,lease,live:{worktree_root:'/tmp/p',branch:'main',head:'abc'}}).ok);
  checks.push(!validateExecutionLease({workItem,scope,lease,live:{worktree_root:'/tmp/other',branch:'main',head:'abc'}}).ok);
  const matrix={audit_cycle:'initial_comprehensive',status:'complete',acceptance_coverage:[0,1].map(i=>({coverage_id:`AC-00${i+1}`,acceptance_index:i,requirement:workItem.acceptance[i],surfaces:['s'],evidence_required:['e'],checks:['c'],status:'covered'}))};
  checks.push(validateAuditCoverage({workItem,matrix}).ok);
  const late=classifyLateFinding({finding:{finding_id:'F-1',materiality:'product_blocker'},coverageMatrix:matrix});
  checks.push(late.origin==='audit_coverage_miss');
  checks.push(resolveContinuationPolicy({assuranceMode:'guarded',openFindings:[{lifecycle_status:'open_confirmed',materiality:'verification_blocker'}],progressState:{status:'progressing'}}).action==='continue_verification_or_close_debt');
  const reviewer={read_only:true,target_head:'abcdef1',implementation_context_id:'i',reviewer_context_id:'r',implementation_root:'/tmp/i',reviewer_root:'/tmp/r',predicate_origin:'protected_reviewer',reviewer_authored_implementation:false,reviewer_authored_artifact_generator:false,reviewer_authored_predicates:false,artifact_manifest_sha256:'a'.repeat(64),independence_status:'independent'};
  checks.push(validateProtectedReviewer(reviewer).ok);
  checks.push(!validateProtectedReviewer({...reviewer,reviewer_context_id:'i'}).ok);
  const fw={status:'active',stage_profile:'protocol_freeze',protected_path_patterns:['src/**/analytics/**'],algorithm_repair_authorized:false};
  checks.push(!validateStageFirewall({firewall:fw,changedPaths:['src/backend/analytics/hrv.ts']}).ok);
  const closure=compileClosure({workItem,findings:[],verificationReceipt:{tests:[{required:true,exit_code:0}]},auditResult:{status:'blocked'},reviewerAttestation:{...reviewer,independence_status:'unavailable'},progressState:{status:'progressing'}});
  checks.push(closure.acceptance_status==='completed_with_verification_debt' && closure.next_owner_goal_allowed===true);
  if (checks.some(x=>!x)) throw new Error(`Self-test failed: ${JSON.stringify(checks)}`);
  return {ok:true,checks:checks.length};
}

if (require.main === module) {
  const [cmd,...rest]=process.argv.slice(2); const args=parseArgs(rest);
  try {
    let out;
    if (cmd==='self-test') out=selfTest();
    else if (cmd==='validate-project') out=validateProject(path.resolve(args['project-root']||'.'));
    else throw new Error('Usage: autonomous-convergence.cjs self-test | validate-project --project-root <path>');
    console.log(JSON.stringify(out,null,2));
    process.exit(out.ok===false?1:0);
  } catch(e) { console.error(e.stack||String(e)); process.exit(1); }
}

const resolveRepairBudget = resolveContinuationPolicy; // historical API alias
module.exports={stable,sha256,normalize,validateBriefContinuity,validateExecutionLease,validateAuditCoverage,classifyLateFinding,resolveContinuationPolicy,resolveRepairBudget,validateProtectedReviewer,validateStageFirewall,compileClosure,liveGit,selfTest};
