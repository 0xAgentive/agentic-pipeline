#!/usr/bin/env node
'use strict';

const assert = require('assert');
const path = require('path');
const core = require(path.resolve(__dirname, '../../scripts/control-plane/autonomous-convergence.cjs'));

const tests = [];
function test(name, fn) { tests.push({ name, fn }); }

function baseWorkItem() {
  return {
    schema_version: '1.0.0',
    work_item_id: 'wi-autonomous-001',
    goal_epoch: 1,
    goal: 'Implement the owner-approved product change',
    assurance_mode: 'guarded',
    owner_approved: true,
    status: 'active',
    brief_revision: 1,
    brief_fingerprint: core.sha256('Implement the owner-approved product change'),
    owner_goal_fingerprint: core.sha256('Implement the owner-approved product change'),
    acceptance: ['Correct behavior', 'Regression safety', 'No scope drift']
  };
}
function baseScope() {
  return {
    schema_version: '1.0.0',
    work_item_id: 'wi-autonomous-001',
    status: 'exact',
    project_root: 'C:/work/product',
    git_head: '1111111111111111111111111111111111111111',
    allowed_paths: ['src/product', 'tests/product'],
    forbidden_domains: ['framework-runtime'],
    generated_at_utc: '2026-07-28T00:00:00Z'
  };
}
function baseLease() {
  const wi = baseWorkItem();
  const scope = baseScope();
  return {
    schema_version: '1.0.0',
    lease_id: 'lease-001',
    status: 'active',
    work_item_id: wi.work_item_id,
    goal_epoch: wi.goal_epoch,
    project_root: scope.project_root,
    worktree_root: scope.project_root,
    branch: 'product/work',
    baseline_head: scope.git_head,
    owner_goal_sha256: core.sha256(wi.goal),
    execution_scope_sha256: core.sha256(scope),
    allowed_paths: scope.allowed_paths,
    first_write_started: false
  };
}
function completeCoverage() {
  const wi = baseWorkItem();
  return {
    schema_version: '1.0.0',
    work_item_id: wi.work_item_id,
    target_head: baseScope().git_head,
    audit_cycle: 'initial_comprehensive',
    status: 'complete',
    acceptance_coverage: wi.acceptance.map((requirement, acceptance_index) => ({
      coverage_id: `AC-${String(acceptance_index + 1).padStart(3, '0')}`,
      acceptance_index,
      requirement,
      surfaces: ['source', 'generated-artifact'],
      evidence_required: ['actual-output'],
      checks: ['semantic-check', 'negative-check'],
      status: 'covered',
      notes: []
    })),
    uncovered_acceptance_indexes: []
  };
}
function independentReviewer(overrides = {}) {
  return {
    schema_version: '1.0.0',
    work_item_id: baseWorkItem().work_item_id,
    target_head: baseScope().git_head,
    implementation_context_id: 'implementation-context',
    reviewer_context_id: 'reviewer-context',
    implementation_root: 'C:/work/product',
    reviewer_root: 'C:/work/reviewer',
    read_only: true,
    artifact_manifest_sha256: 'a'.repeat(64),
    predicate_origin: 'protected_reviewer',
    reviewer_authored_implementation: false,
    reviewer_authored_artifact_generator: false,
    reviewer_authored_predicates: false,
    independence_status: 'independent',
    ...overrides
  };
}

test('pre-write lease rejects wrong worktree', () => {
  const r = core.validateExecutionLease({
    workItem: baseWorkItem(), scope: baseScope(), lease: baseLease(),
    live: { worktree_root: 'C:/work/wrong', branch: 'product/work', head: baseScope().git_head }
  });
  assert.strictEqual(r.ok, false);
  assert(r.errors.includes('WORKTREE_ROOT_MISMATCH'));
});

test('pre-write lease rejects branch drift', () => {
  const r = core.validateExecutionLease({
    workItem: baseWorkItem(), scope: baseScope(), lease: baseLease(),
    live: { worktree_root: 'C:/work/product', branch: 'research/old', head: baseScope().git_head }
  });
  assert.strictEqual(r.ok, false);
  assert(r.errors.includes('BRANCH_MISMATCH'));
});

test('immutable brief rejects regenerated owner brief', () => {
  const previous = baseWorkItem();
  const current = { ...previous, goal: 'Expanded goal', brief_revision: 2, brief_fingerprint: core.sha256('Expanded goal') };
  const r = core.validateBriefContinuity({ previous, current });
  assert.strictEqual(r.ok, false);
  assert(r.errors.includes('OWNER_GOAL_CHANGED'));
  assert(r.errors.includes('BRIEF_REVISION_CHANGED'));
});

test('initial comprehensive audit requires complete acceptance coverage', () => {
  const matrix = completeCoverage();
  matrix.acceptance_coverage.pop();
  const r = core.validateAuditCoverage({ workItem: baseWorkItem(), matrix });
  assert.strictEqual(r.ok, false);
  assert(r.errors.some(x => x.startsWith('ACCEPTANCE_NOT_COVERED:')));
});

test('late material finding becomes audit coverage miss', () => {
  const finding = { finding_id: 'F-LATE-001', materiality: 'product_blocker', lifecycle_status: 'open_confirmed' };
  const classified = core.classifyLateFinding({ finding, coverageMatrix: completeCoverage() });
  assert.strictEqual(classified.origin, 'audit_coverage_miss');
});

test('repair history never requires owner authorization while progress continues', () => {
  const r = core.resolveRepairBudget({
    assuranceMode: 'guarded',
    budget: { repair_batches_used: 99, repair_batch_limit: 3 },
    progressState: { status: 'progressing', observations_count: 99 },
    openFindings: [{ finding_id: 'PF-1', lifecycle_status: 'open_confirmed', materiality: 'product_blocker' }]
  });
  assert.strictEqual(r.status, 'available');
  assert.strictEqual(r.limit, null);
  assert.strictEqual(r.action, 'continue_grouped_repair');
});

test('repeated no-progress stops without asking for another repair batch', () => {
  const r = core.resolveRepairBudget({
    assuranceMode: 'guarded',
    budget: { repair_batches_used: 99, repair_batch_limit: 3 },
    progressState: { status: 'stalled', observations_count: 99, owner_decision_required: false },
    openFindings: [{ finding_id: 'PF-1', lifecycle_status: 'open_confirmed', materiality: 'product_blocker' }]
  });
  assert.strictEqual(r.status, 'stalled');
  assert.strictEqual(r.action, 'hard_stop_no_progress');
});

test('self-authored audit is not independent', () => {
  const r = core.validateProtectedReviewer(independentReviewer({
    predicate_origin: 'implementation_context', reviewer_authored_predicates: true, independence_status: 'not_independent'
  }));
  assert.strictEqual(r.ok, false);
  assert(r.errors.includes('SELF_AUTHORED_PREDICATES'));
});

test('audit on different HEAD is rejected', () => {
  const r = core.validateProtectedReviewer(independentReviewer(), { target_head: '2222222222222222222222222222222222222222' });
  assert.strictEqual(r.ok, false);
  assert(r.errors.includes('AUDIT_TARGET_HEAD_MISMATCH'));
});

test('audit on different artifact manifest is rejected', () => {
  const r = core.validateProtectedReviewer(independentReviewer(), { artifact_manifest_sha256: 'b'.repeat(64) });
  assert.strictEqual(r.ok, false);
  assert(r.errors.includes('AUDIT_ARTIFACT_MANIFEST_MISMATCH'));
});

test('protocol freeze blocks production analytics drift', () => {
  const firewall = {
    status: 'active', stage_profile: 'protocol_freeze',
    protected_path_patterns: ['src/**/analytics/**', 'src/**/hrv/**'],
    algorithm_repair_authorized: false
  };
  const r = core.validateStageFirewall({ firewall, changedPaths: ['src/backend/analytics/hrv.ts'] });
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.code, 'SCIENTIFIC_STAGE_FIREWALL_BLOCKED');
});

test('authorized algorithm repair can cross scientific firewall', () => {
  const firewall = {
    status: 'active', stage_profile: 'protocol_freeze',
    protected_path_patterns: ['src/**/analytics/**'],
    algorithm_repair_authorized: true,
    algorithm_repair_finding_ids: ['ALG-001']
  };
  const r = core.validateStageFirewall({ firewall, changedPaths: ['src/backend/analytics/hrv.ts'] });
  assert.strictEqual(r.ok, true);
});

test('single authority compiler closes unavailable protected audit with verification debt', () => {
  const closure = core.compileClosure({
    workItem: baseWorkItem(),
    findings: [],
    verificationReceipt: { tests: [{ name: 'typecheck', required: true, exit_code: 0 }] },
    auditResult: null,
    reviewerAttestation: null,
    budget: { repair_batches_used: 3 }
  });
  assert.strictEqual(closure.acceptance_status, 'completed_with_verification_debt');
  assert.strictEqual(closure.next_owner_goal_allowed, true);
  assert.strictEqual(closure.release_status, 'blocked');
});

test('single authority compiler keeps open product blocker in automatic repair while progress is possible', () => {
  const closure = core.compileClosure({
    workItem: baseWorkItem(),
    findings: [{ finding_id: 'F-1', lifecycle_status: 'open_confirmed', materiality: 'product_blocker' }],
    verificationReceipt: { tests: [{ name: 'typecheck', required: true, exit_code: 0 }] },
    auditResult: { status: 'passed' },
    reviewerAttestation: independentReviewer(),
    budget: { repair_batches_used: 1 }
  });
  assert.strictEqual(closure.acceptance_status, 'not_evaluated');
  assert.strictEqual(closure.implementation_status, 'in_progress');
  assert.strictEqual(closure.next_workflow, '/fixcritical');
  assert.strictEqual(closure.next_owner_goal_allowed, false);
});

let passed = 0;
for (const t of tests) {
  try {
    t.fn();
    passed += 1;
    process.stdout.write(`PASS ${t.name}\n`);
  } catch (error) {
    process.stderr.write(`FAIL ${t.name}\n${error.stack || error}\n`);
    process.exit(1);
  }
}
process.stdout.write(`Autonomous convergence acceptance: ${passed}/${tests.length} passed.\n`);
