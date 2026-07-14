#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { resolveRuntimeRoute } = require(
  path.resolve(__dirname, '../../scripts/control-plane/resolve-runtime-route.cjs')
);

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    const output = {};
    for (const key of Object.keys(value).sort()) output[key] = canonical(value[key]);
    return output;
  }
  return value;
}

function baseFacts() {
  return {
    project_inventory: {
      source: 'project_command_inventory',
      trust: 'authoritative',
      inventory_path: '.agents/COMMAND_INVENTORY.json',
      inventory_sha256: 'a'.repeat(64),
      commands: [
        '/landing',
        '/auditphase',
        '/fixcritical',
        '/shipcheck',
        '/specdoc',
        '/planonly',
        '/nextphase'
      ]
    },
    installation_facts: {
      installation_manifest_path: '.agy/INSTALLATION_MANIFEST.json',
      installation_manifest_sha256: 'b'.repeat(64),
      installed_project_package_version: '1.2.4',
      installed_project_runtime_version: '1.2.1',
      installed_project_source_commit: 'fixture'
    },
    central_inventory_advisory: {
      package_version: '1.2.4',
      runtime_version: '1.2.1',
      commands: ['/landing', '/auditphase', '/fixcritical', '/shipcheck', '/nextphase']
    },
    git_facts: {
      git_state: 'clean',
      head_commit: 'fixture'
    },
    state_facts: {
      current_phase: 'P1',
      current_status: 'awaiting_audit',
      next_required_command: '/landing',
      commands_allowed_now: ['/landing', '/shipcheck']
    },
    phase_contract_facts: {
      contract_hash: 'contract',
      contract_status: 'started'
    },
    phase_result_facts: {
      present: true,
      structurally_valid: true,
      contract_hash_valid: true,
      valid: true,
      missing: false,
      contract_hash: 'contract',
      source_commit: 'fixture'
    },
    acceptance_facts: {
      acceptance_status: 'blocked',
      audit_status: 'passed',
      verification_status: 'passed',
      ship_status: 'no_ship',
      open_confirmed_current_phase_blockers: 0,
      repair_required_current_phase_findings: 0,
      verification_required_current_phase_findings: 0,
      fixed_unverified_current_phase_findings: 0
    },
    audit_facts: {
      audit_result_present: true,
      audit_result_structurally_valid: true,
      audit_authoritative: true,
      audit_evidence_complete: true,
      claims_evidence_consistent: true
    },
    repair_facts: {
      repair_budget_known: true,
      repair_budget_exhausted: false,
      user_continue_repair_authorized: false,
      registered_repair_cycle_count: 0
    },
    routing_policy: {
      explicit_compatibility_matrix: {}
    },
    requested_command: null
  };
}

function expectedSubset(actual, expected, prefix = '') {
  const errors = [];
  for (const [key, value] of Object.entries(expected)) {
    const location = prefix ? `${prefix}.${key}` : key;
    if (Array.isArray(value)) {
      if (!Array.isArray(actual[key]) || JSON.stringify(actual[key]) !== JSON.stringify(value)) {
        errors.push(`${location}: expected ${JSON.stringify(value)}, got ${JSON.stringify(actual[key])}`);
      }
    } else if (value && typeof value === 'object') {
      errors.push(...expectedSubset(actual[key] || {}, value, location));
    } else if (actual[key] !== value) {
      errors.push(`${location}: expected ${JSON.stringify(value)}, got ${JSON.stringify(actual[key])}`);
    }
  }
  return errors;
}

const cases = [
  {
    id: 'dirty_git_requires_landing',
    mutate(f) { f.git_facts.git_state = 'dirty'; },
    expected: {
      routing_mode: 'recovery',
      next_required_command: '/landing',
      resolved_commands_allowed_now: ['/landing', '/auditphase'],
      routing_decision: 'route'
    },
    reason: 'DIRTY_GIT_REQUIRES_RECOVERY'
  },
  {
    id: 'dirty_git_blocks_fixcritical',
    mutate(f) { f.git_facts.git_state = 'dirty'; f.requested_command = '/fixcritical'; },
    expected: { routing_decision: 'fail_closed', command: null }
  },
  {
    id: 'dirty_git_blocks_nextphase',
    mutate(f) { f.git_facts.git_state = 'dirty'; f.requested_command = '/nextphase P8.0'; },
    expected: { routing_decision: 'fail_closed', command: null }
  },
  {
    id: 'dirty_git_blocks_shipcheck',
    mutate(f) { f.git_facts.git_state = 'dirty'; f.requested_command = '/shipcheck release'; },
    expected: { routing_decision: 'fail_closed', command: null }
  },
  {
    id: 'awaiting_audit_is_objective',
    mutate(f) {
      f.state_facts.current_status = 'awaiting_audit';
      f.state_facts.commands_allowed_now = ['/landing', '/shipcheck'];
    },
    expected: {
      next_required_command: '/auditphase',
      resolved_commands_allowed_now: ['/auditphase']
    },
    reason: 'AWAITING_AUDIT'
  },
  {
    id: 'confirmed_blocker_requires_fixcritical',
    mutate(f) {
      f.state_facts.current_status = 'acceptance_blocked';
      f.acceptance_facts.open_confirmed_current_phase_blockers = 1;
      f.state_facts.next_required_command = '/landing';
      f.state_facts.commands_allowed_now = ['/landing'];
    },
    expected: {
      next_required_command: '/fixcritical',
      resolved_commands_allowed_now: ['/auditphase', '/fixcritical']
    },
    reason: 'CONFIRMED_BLOCKER_REQUIRES_REPAIR'
  },
  {
    id: 'completed_landing_does_not_loop',
    mutate(f) {
      f.state_facts.current_status = 'awaiting_audit';
      f.state_facts.state_handoff_required = true;
      f.state_facts.landing_completed = true;
      f.state_facts.next_required_command = '/landing';
    },
    expected: {
      next_required_command: '/auditphase',
      resolved_commands_allowed_now: ['/auditphase']
    },
    reason: 'LANDING_ALREADY_COMPLETED'
  },
  {
    id: 'fixed_unverified_requires_audit',
    mutate(f) {
      f.state_facts.current_status = 'acceptance_blocked';
      f.acceptance_facts.fixed_unverified_current_phase_findings = 1;
    },
    expected: {
      next_required_command: '/auditphase',
      resolved_commands_allowed_now: ['/auditphase']
    },
    reason: 'FIXED_UNVERIFIED_REQUIRES_AUDIT'
  },
  {
    id: 'central_inventory_cannot_authorize',
    mutate(f) {
      f.project_inventory.commands = ['/auditphase'];
      f.state_facts.current_status = 'acceptance_blocked';
      f.acceptance_facts.open_confirmed_current_phase_blockers = 1;
    },
    expected: {
      routing_valid: false,
      next_required_command: null
    }
  },
  {
    id: 'specification_required',
    mutate(f) { f.state_facts.current_status = 'specification_required'; },
    expected: {
      next_required_command: '/specdoc',
      resolved_commands_allowed_now: ['/specdoc']
    },
    reason: 'SPECIFICATION_REQUIRED'
  },
  {
    id: 'planning_required',
    mutate(f) { f.state_facts.current_status = 'planning_required'; },
    expected: {
      next_required_command: '/planonly',
      resolved_commands_allowed_now: ['/planonly']
    },
    reason: 'PLANNING_REQUIRED'
  },
  {
    id: 'implementation_ready',
    mutate(f) { f.state_facts.current_status = 'implementation_ready'; },
    expected: {
      next_required_command: '/nextphase',
      resolved_commands_allowed_now: ['/auditphase', '/nextphase']
    },
    reason: 'IMPLEMENTATION_READY'
  },
  {
    id: 'implementation_in_progress_with_valid_result_routes_audit',
    mutate(f) { f.state_facts.current_status = 'implementation_in_progress'; },
    expected: {
      next_required_command: '/auditphase',
      resolved_commands_allowed_now: ['/auditphase']
    }
  },
  {
    id: 'implementation_in_progress_without_result_fails_closed',
    mutate(f) {
      f.state_facts.current_status = 'implementation_in_progress';
      f.phase_result_facts.present = false;
      f.phase_result_facts.structurally_valid = false;
      f.phase_result_facts.valid = false;
      f.phase_result_facts.missing = true;
    },
    expected: {
      routing_decision: 'fail_closed',
      next_required_command: null
    },
    reason: 'PHASE_RESULT_AUTHORITY_UNPROVEN'
  },
  {
    id: 'recovery_required_status',
    mutate(f) { f.state_facts.current_status = 'recovery_required'; },
    expected: {
      routing_mode: 'recovery',
      next_required_command: '/landing'
    },
    reason: 'OBJECTIVE_STALE_STATE'
  },
  {
    id: 'shipcheck_is_reachable_before_ship',
    mutate(f) {
      f.state_facts.current_status = 'release_candidate_ready';
      f.acceptance_facts.acceptance_status = 'accepted';
      f.acceptance_facts.audit_status = 'passed';
      f.acceptance_facts.verification_status = 'passed';
      f.acceptance_facts.ship_status = null;
    },
    expected: {
      next_required_command: '/shipcheck',
      resolved_commands_allowed_now: ['/shipcheck']
    },
    reason: 'SHIPCHECK_ELIGIBLE'
  },
  {
    id: 'already_shipped_is_terminal',
    mutate(f) {
      f.state_facts.current_status = 'release_candidate_ready';
      f.acceptance_facts.acceptance_status = 'accepted';
      f.acceptance_facts.audit_status = 'passed';
      f.acceptance_facts.verification_status = 'passed';
      f.acceptance_facts.ship_status = 'ship';
    },
    expected: {
      routing_decision: 'already_shipped',
      next_required_command: null
    },
    reason: 'FINAL_SHIP_DECISION_ALREADY_PRESENT'
  },
  {
    id: 'runtime_exact_match',
    mutate() {},
    expected: { runtime_compatibility: 'compatible' }
  },
  {
    id: 'runtime_mismatch_requires_migration',
    mutate(f) { f.installation_facts.installed_project_runtime_version = '1.1.0'; },
    expected: { runtime_compatibility: 'migration_required' },
    reason: 'RUNTIME_MIGRATION_REQUIRED'
  },
  {
    id: 'runtime_unknown_remains_unknown',
    mutate(f) { f.installation_facts.installed_project_runtime_version = 'unknown'; },
    expected: { runtime_compatibility: 'unknown' },
    reason: 'RUNTIME_IDENTITY_UNKNOWN'
  },
  {
    id: 'explicit_compatibility_matrix',
    mutate(f) {
      f.installation_facts.installed_project_runtime_version = '1.2.0';
      f.routing_policy.explicit_compatibility_matrix = { '1.2.0': '1.2.1' };
    },
    expected: { runtime_compatibility: 'compatible' }
  },
  {
    id: 'command_arguments_are_normalized',
    mutate(f) {
      f.state_facts.current_status = 'implementation_ready';
      f.requested_command = '/nextphase P8.0';
    },
    expected: {
      routing_decision: 'route',
      command: '/nextphase'
    }
  },
  {
    id: 'whitespace_request_is_rejected',
    mutate(f) {
      f.state_facts.current_status = 'implementation_ready';
      f.requested_command = '   ';
    },
    expected: {
      routing_decision: 'reject_unknown_command',
      command: null,
      routing_valid: false
    }
  },
  {
    id: 'non_slash_request_is_rejected',
    mutate(f) {
      f.state_facts.current_status = 'implementation_ready';
      f.requested_command = 'nextphase';
    },
    expected: {
      routing_decision: 'reject_unknown_command',
      command: null,
      routing_valid: false
    }
  }
];

function loadGoldenBaseline() {
  const baselinePath = path.join(__dirname, 'golden-cases-baseline.json');
  const currentPath = path.resolve(__dirname, '../../evals/companion/golden_cases.json');
  return {
    baseline: JSON.parse(fs.readFileSync(baselinePath, 'utf8')),
    current: JSON.parse(fs.readFileSync(currentPath, 'utf8'))
  };
}

function validateGoldenBaseline() {
  const { baseline, current } = loadGoldenBaseline();
  const currentIds = new Set((current.cases || []).map((item) => item.id));
  const errors = [];

  if (!Array.isArray(baseline.case_ids) || !Number.isInteger(baseline.case_count)) {
    errors.push('Malformed golden-cases baseline');
  } else {
    for (const id of baseline.case_ids) {
      if (!currentIds.has(id)) errors.push(`Original golden case deleted: ${id}`);
    }
    if ((current.cases || []).length < baseline.case_count) {
      errors.push(`Golden case count decreased: baseline=${baseline.case_count} current=${(current.cases || []).length}`);
    }
  }

  return errors;
}

function selfCheck() {
  const ids = new Set();
  const errors = [];
  if (cases.length < 24) errors.push(`Expected at least 24 cases, found ${cases.length}`);
  for (const item of cases) {
    if (!item.id || typeof item.mutate !== 'function' || !item.expected) {
      errors.push(`Malformed case: ${JSON.stringify(item)}`);
    }
    if (ids.has(item.id)) errors.push(`Duplicate case id: ${item.id}`);
    ids.add(item.id);
  }
  errors.push(...validateGoldenBaseline());

  if (errors.length) {
    for (const error of errors) console.error(`SELF-CHECK FAIL: ${error}`);
    process.exit(1);
  }
  console.log(`Acceptance contract self-check passed. Cases: ${cases.length}`);
}

function run() {
  const failures = validateGoldenBaseline();
  for (const item of cases) {
    const facts = clone(baseFacts());
    item.mutate(facts);
    let actual;
    try {
      actual = resolveRuntimeRoute(facts);
    } catch (error) {
      failures.push(`${item.id}: resolver threw ${error.stack || error.message}`);
      continue;
    }
    const errors = expectedSubset(actual, item.expected);
    if (item.reason) {
      const reasons = actual.routing_reason_codes || [];
      if (!Array.isArray(reasons) || !reasons.includes(item.reason)) {
        errors.push(`routing_reason_codes missing ${item.reason}: ${JSON.stringify(reasons)}`);
      }
    }
    if (errors.length) failures.push(`${item.id}: ${errors.join('; ')}`);
  }

  if (failures.length) {
    console.error(`Runtime routing acceptance failed: ${failures.length}/${cases.length}`);
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }
  console.log(`Runtime routing acceptance passed. Cases: ${cases.length}`);
}

if (process.argv.includes('--self-check')) selfCheck();
else run();
