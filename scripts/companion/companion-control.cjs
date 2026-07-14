#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const { resolveRuntimeRoute } = require('../control-plane/resolve-runtime-route.cjs');

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const result = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        result[key] = next;
        i += 1;
      } else {
        result[key] = true;
      }
    } else {
      result._.push(arg);
    }
  }
  return result;
}

function readText(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function readJson(filePath) {
  return JSON.parse(readText(filePath));
}

function sha256Bytes(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function sha256File(filePath) {
  return sha256Bytes(fs.readFileSync(filePath));
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value && typeof value === 'object') {
    const output = {};
    for (const key of Object.keys(value).sort()) {
      if (key === 'contract_hash') continue;
      output[key] = canonicalize(value[key]);
    }
    return output;
  }
  return value;
}

function canonicalHash(value) {
  const text = JSON.stringify(canonicalize(value));
  return sha256Bytes(Buffer.from(text, 'utf8'));
}

function rootCommand(value) {
  if (!value || typeof value !== 'string') return null;
  const match = value.trim().match(/^\/[^\s]+/);
  return match ? match[0] : null;
}

function makeResult(input, partial) {
  let resolved = partial.resolved_commands_allowed_now || input.available_commands || [];
  if (input.repair_budget_exhausted && !input.user_continue_repair_authorized) {
    const blocked = new Set(['/fixcritical', '/nextphase', '/fastpatch']);
    resolved = resolved.filter(cmd => !blocked.has(cmd));
  }
  return {
    decision: partial.decision,
    command: partial.command,
    routing_mode: partial.routing_mode || 'normal',
    resolved_commands_allowed_now: resolved,
    next_required_command: partial.next_required_command || null,
    routing_valid: partial.routing_valid !== undefined ? partial.routing_valid : true,
    routing_errors: partial.routing_errors || [],
    reason_codes: partial.reason_codes || []
  };
}

function route(input) {
  const available = new Set(input.available_commands || []);
  const allowed = new Set(input.commands_allowed_now || []);
  const requested = input.requested_command || null;

  if (requested && !available.has(requested)) {
    return makeResult(input, { decision: 'reject_unknown_command', command: null, routing_valid: false, routing_errors: [`Requested command '${requested}' is not installed in project-local inventory.`] });
  }
  if (input.repair_budget_exhausted && !input.user_continue_repair_authorized) {
    return makeResult(input, { decision: 'human_decision_required', command: null });
  }
  if (input.required_child_exit_codes && input.required_child_exit_codes.some((code) => Number(code) !== 0)) {
    return makeResult(input, { decision: 'fail_closed', command: null, routing_valid: false });
  }
  if (input.production_outputs_changed_by_tests) {
    return makeResult(input, { decision: 'block_test_isolation', command: null, routing_valid: false });
  }
  if (input.zip_hash_embedded_inside_zip) {
    return makeResult(input, { decision: 'reject_self_reference', command: null, routing_valid: false });
  }
  if (input.contract_status === 'started' && input.new_acceptance_criteria) {
    return makeResult(input, { decision: 'classify_new_requirement', command: null });
  }
  if (input.risk_track === 'research' && input.finding_category === 'delivery' && input.affects_validity === false) {
    return makeResult(input, { decision: 'defer_non_blocking_debt', command: null });
  }
  if (input.artifact_metadata_stale && input.product_behavior_valid) {
    return makeResult(input, { decision: 'invalidate_artifact_claim_only', command: available.has('/auditphase') ? '/auditphase' : null });
  }
  if (input.phase_result_present === false && input.completion_prose_present) {
    return makeResult(input, { decision: 'report_unverified', command: null });
  }
  if (input.exact_version_contract === false && input.imports_pass && input.tests_pass) {
    return makeResult(input, { decision: 'accept_environment_deviation', command: null });
  }
  if (input.finding_lifecycle_status === 'verified_resolved') {
    return makeResult(input, { decision: 'exclude_from_open_count', command: null });
  }
  if (input.implementation_alignment_status === 'resolved' && input.empirical_validation_status === 'unvalidated') {
    return makeResult(input, { decision: 'keep_production_use_conditional', command: null });
  }
  if (input.market_content_hash_match === true && input.provenance_hash_match === false) {
    return makeResult(input, { decision: 'accept_content_reject_provenance_identity', command: null });
  }

  // Construct facts for resolveRuntimeRoute
  const facts = {
    project_inventory: input.project_local_available_commands
      ? {
          source: input.inventory_source || 'project_local',
          commands: input.project_local_available_commands
        }
      : (input.available_commands
          ? {
              source: input.inventory_source || 'project_local',
              commands: input.available_commands
            }
          : { source: 'missing' }),
    central_inventory_advisory: {
      commands: ['/specdoc', '/planonly', '/auditphase', '/probephase', '/nextphase', '/fastpatch', '/visualqa', '/reportqa', '/securityaudit', '/artifactaudit', '/shipcheck', '/landing', '/triage', '/codebase-map', '/parallel-audit', '/phasebatch', '/fixcritical', '/lessons', '/githubprepare', '/githubsync'],
      runtime_version: '1.2.0'
    },
    git_facts: {
      git_state: input.git_state || 'clean',
      head_commit: input.head_commit
    },
    state_facts: {
      current_status: input.current_status,
      commands_allowed_now: input.state_declared_commands_allowed_now || input.commands_allowed_now,
      stale_state: input.stale_state,
      evidence_state: input.evidence_state,
      only_state_handoff: input.only_state_handoff,
      confirmed_blockers: input.confirmed_blockers,
      next_required_command: input.state_declared_next_required_command || input.next_required_command,
      state_handoff_required: input.state_handoff_required,
      landing_completed: input.landing_completed,
      recovery_required: input.recovery_required
    },
    phase_contract_facts: {
      contract_status: input.contract_status,
      new_acceptance_criteria: input.new_acceptance_criteria
    },
    phase_result_facts: {
      valid: input.phase_result_present !== false,
      missing: input.phase_result_present === false,
      contract_hash: input.contract_hash,
      release_source_commit: input.release_source_commit,
      source_commit: input.source_commit
    },
    acceptance_facts: {
      acceptance_status: input.acceptance_status,
      audit_status: input.audit_status,
      verification_status: input.verification_status,
      ship_status: input.ship_status,
      open_confirmed_current_phase_blockers: input.open_confirmed_current_phase_blockers !== undefined ? input.open_confirmed_current_phase_blockers : (input.open_current_phase_blockers !== undefined ? input.open_current_phase_blockers : 0),
      repair_required_current_phase_findings: input.repair_required_current_phase_findings !== undefined ? input.repair_required_current_phase_findings : 0,
      verification_required_current_phase_findings: input.verification_required_current_phase_findings !== undefined ? input.verification_required_current_phase_findings : 0,
      fixed_unverified_current_phase_findings: input.fixed_unverified_current_phase_findings !== undefined ? input.fixed_unverified_current_phase_findings : 0,
      verified_resolved_findings: input.verified_resolved_findings !== undefined ? input.verified_resolved_findings : 0,
      deferred_product_findings: input.deferred_product_findings !== undefined ? input.deferred_product_findings : 0,
      deferred_infrastructure_findings: input.deferred_infrastructure_findings !== undefined ? input.deferred_infrastructure_findings : 0,
      accepted_risks: input.accepted_risks !== undefined ? input.accepted_risks : 0
    },
    audit_facts: {
      audit_result_present: input.audit_result_present !== undefined ? input.audit_result_present : true,
      audit_result_schema_valid: input.audit_result_schema_valid !== undefined ? input.audit_result_schema_valid : true,
      audit_authoritative: input.audit_authoritative !== undefined ? input.audit_authoritative : true,
      audit_evidence_complete: input.audit_evidence_complete !== undefined ? input.audit_evidence_complete : true,
      claims_evidence_consistent: input.claims_evidence_consistent !== undefined ? input.claims_evidence_consistent : true
    },
    repair_facts: {
      repair_budget_known: input.repair_budget_known !== undefined ? input.repair_budget_known : true,
      repair_budget_exhausted: input.repair_budget_exhausted !== undefined ? input.repair_budget_exhausted : false,
      user_continue_repair_authorized: input.user_continue_repair_authorized !== undefined ? input.user_continue_repair_authorized : false,
      registered_repair_cycle_count: input.registered_repair_cycle_count !== undefined ? input.registered_repair_cycle_count : 1
    },
    requested_command: input.requested_command !== undefined ? input.requested_command : null,
    routing_policy: {
      allow_triage: false
    }
  };

  const res = resolveRuntimeRoute(facts);
  return {
    decision: res.decision,
    command: res.command,
    routing_mode: res.routing_mode,
    resolved_commands_allowed_now: res.resolved_commands_allowed_now,
    next_required_command: res.next_required_command,
    routing_valid: res.routing_valid,
    routing_errors: res.routing_errors,
    reason_codes: res.stale_reasons ? res.stale_reasons.map(r => r.code) : []
  };
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function activeCompanionFiles(repoRoot) {
  return [
    'docs/companion/00_AGENTIC_PIPELINE_INDEX_v1.2.2.md',
    'docs/companion/01_CONTEXT_SPLIT_POLICY.md',
    'docs/companion/02_AGENT_TASK_PACK_CONTRACT_v1.2.2.md',
    'docs/companion/03_PRODUCT_EVIDENCE_CONTROL_PLANE.md',
    'docs/companion/04_PROJECT_AUDIT_AND_RECOVERY.md',
    'docs/companion/05_DOMAIN_SPECIFIC_LESSONS_OPTIONAL.md',
    'docs/companion/06_RUNTIME_TRUTH_REVIEW_POLICY.md',
    'docs/companion/07_RUNTIME_HANDSHAKE_AND_COMMAND_ROUTING.md',
    'docs/companion/08_PHASE_CONTRACT_AND_REPAIR_BUDGET.md',
    'docs/companion/09_EVIDENCE_LEVELS_AND_BLOCKER_POLICY.md',
    'docs/companion/10_STATUS_AND_FINDING_LIFECYCLE.md',
    'docs/companion/11_PROMPT_COMPILER_AND_RESULT_AUTHORITY.md',
    'docs/companion/12_GOLDEN_EVALS.md',
    'docs/companion/13_LOCAL_CONTROL_TOOLS.md',
    'docs/companion/SYSTEM_PROMPT_GPT55_COMPANION_v1.2.2.md',
    'docs/companion/README_INSTALL_RU_v1.2.2.md',
    'docs/companion/README.md',
    'docs/companion/VERSION.json',
  ].map((p) => path.join(repoRoot, p));
}

function validatePack(repoRoot) {
  const errors = [];
  const warnings = [];
  for (const filePath of activeCompanionFiles(repoRoot)) {
    if (!fs.existsSync(filePath)) errors.push(`Missing active companion file: ${path.relative(repoRoot, filePath)}`);
  }

  const schemaDir = path.join(repoRoot, 'schemas', 'companion');
  for (const name of ['runtime-handshake.schema.json', 'phase-contract.schema.json', 'finding.schema.json', 'phase-result.schema.json', 'repair-ledger-record.schema.json']) {
    const p = path.join(schemaDir, name);
    if (!fs.existsSync(p)) {
      errors.push(`Missing schema: schemas/companion/${name}`);
    } else {
      try { readJson(p); } catch (err) { errors.push(`Invalid JSON schema ${name}: ${err.message}`); }
    }
  }

  const versionPath = path.join(repoRoot, 'docs', 'companion', 'VERSION.json');
  if (fs.existsSync(versionPath)) {
    const version = readJson(versionPath);
    if (version.companion_version !== '1.2.2') errors.push('Companion VERSION.json does not declare 1.2.2');
  }

  const systemPath = path.join(repoRoot, 'docs', 'companion', 'SYSTEM_PROMPT_GPT55_COMPANION_v1.2.2.md');
  if (fs.existsSync(systemPath)) {
    const text = readText(systemPath);
    const markers = [
      'Mandatory runtime handshake',
      'Never emit `/recovery`',
      'Frozen phase contract',
      'Repair budget',
      'E0-E4',
      'Result authority',
      'fail-closed',
      'Implementation alignment does not equal empirical or scientific validation',
    ];
    for (const marker of markers) if (!text.includes(marker)) errors.push(`System prompt missing marker: ${marker}`);
  }

  const indexPath = path.join(repoRoot, 'docs', 'companion', '00_AGENTIC_PIPELINE_INDEX_v1.2.2.md');
  if (fs.existsSync(indexPath)) {
    const index = readText(indexPath);
    for (let n = 7; n <= 13; n += 1) {
      const prefix = String(n).padStart(2, '0') + '_';
      if (!index.includes(prefix)) errors.push(`Companion index does not list ${prefix} policy`);
    }
  }

  const oldActive = [
    'docs/companion/00_AGENTIC_PIPELINE_INDEX_v1.2.1.md',
    'docs/companion/02_AGENT_TASK_PACK_CONTRACT_v1.2.1.md',
    'docs/companion/README_INSTALL_RU_v1.2.1.md',
    'docs/companion/SYSTEM_PROMPT_GPT55_COMPANION_v1.2.1.md',
  ];
  for (const rel of oldActive) if (fs.existsSync(path.join(repoRoot, rel))) errors.push(`Legacy active companion file remains in root: ${rel}`);

  const evalPath = path.join(repoRoot, 'evals', 'companion', 'golden_cases.json');
  if (!fs.existsSync(evalPath)) {
    errors.push('Missing golden eval cases');
  } else {
    const evals = readJson(evalPath);
    if (!Array.isArray(evals.cases) || evals.cases.length < 16) errors.push('Golden eval suite must contain at least 16 cases');
    const ids = new Set();
    for (const item of evals.cases || []) {
      if (!item.id || !item.input || !item.expected) errors.push('Malformed golden eval case');
      if (ids.has(item.id)) errors.push(`Duplicate golden eval id: ${item.id}`);
      ids.add(item.id);
      const fullRes = route(item.input);
      const actual = {};
      for (const key of Object.keys(item.expected)) {
        actual[key] = fullRes[key];
      }
      if (!deepEqual(actual, item.expected)) {
        errors.push(`Golden eval failed: ${item.id}; expected=${JSON.stringify(item.expected)} actual=${JSON.stringify(actual)}`);
      }
    }
  }

  const commandInventory = path.join(repoRoot, 'config', 'command-inventory.json');
  if (fs.existsSync(commandInventory)) {
    const inv = readJson(commandInventory);
    const commands = new Set((inv.commands || []).map((x) => x.command));
    if (commands.has('/recovery')) errors.push('Runtime command inventory unexpectedly contains /recovery');
    for (const required of ['/auditphase', '/fixcritical', '/landing', '/nextphase']) {
      if (!commands.has(required)) warnings.push(`Runtime inventory does not contain expected route ${required}`);
    }
  }

  const activeDocs = activeCompanionFiles(repoRoot).filter((p) => p.endsWith('.md') && fs.existsSync(p));
  const absolutePathPattern = /[A-Za-z]:\\Users\\|file:\/\/\//i;
  for (const p of activeDocs) {
    const text = readText(p);
    if (absolutePathPattern.test(text)) errors.push(`Active companion doc contains local absolute path or file URI: ${path.relative(repoRoot, p)}`);
  }

  return { ok: errors.length === 0, errors, warnings };
}

function validateContract(projectRoot) {
  const errors = [];
  const contractPath = path.join(projectRoot, '.agy', 'PHASE_CONTRACT.json');
  const lockPath = path.join(projectRoot, '.agy', 'PHASE_CONTRACT.lock.json');
  if (!fs.existsSync(contractPath)) return { ok: false, errors: ['Missing .agy/PHASE_CONTRACT.json'] };
  const contract = readJson(contractPath);
  for (const key of ['phase_id', 'goal', 'risk_track', 'evidence_level', 'status', 'repair_budget', 'next_allowed_commands', 'contract_hash']) {
    if (contract[key] === undefined) errors.push(`Phase contract missing ${key}`);
  }
  const actual = canonicalHash(contract);
  if (contract.contract_hash !== actual) errors.push(`Phase contract hash mismatch: expected=${contract.contract_hash} actual=${actual}`);
  if (fs.existsSync(lockPath)) {
    const lock = readJson(lockPath);
    if (lock.contract_hash !== contract.contract_hash) errors.push('Phase contract lock hash differs from contract');
  } else if (contract.status !== 'draft') {
    errors.push('Frozen/started/closed phase contract has no lock file');
  }
  return { ok: errors.length === 0, errors, contract_hash: actual };
}

function validateResult(projectRoot) {
  const errors = [];
  const resultPath = path.join(projectRoot, '.agy', 'PHASE_RESULT.json');
  if (!fs.existsSync(resultPath)) return { ok: false, errors: ['Missing .agy/PHASE_RESULT.json'] };
  const result = readJson(resultPath);
  const contractCheck = validateContract(projectRoot);
  if (!contractCheck.ok) errors.push(...contractCheck.errors);
  if (result.contract_hash !== contractCheck.contract_hash) errors.push('Phase result contract_hash does not match phase contract');
  const failedRequired = (result.command_results || []).filter((x) => x.required && Number(x.exit_code) !== 0);
  if (failedRequired.length && ['completed', 'passed', 'accepted', 'ship'].includes(result.implementation_status)) {
    errors.push('Phase result reports success while a required command failed');
  }
  if (failedRequired.length && result.verification_status === 'passed') errors.push('verification_status=passed with failed required command');
  if ((result.blockers || []).length && result.acceptance_status === 'accepted') errors.push('acceptance_status=accepted while blockers remain');
  if (result.ship_status === 'ship' && result.acceptance_status !== 'accepted') errors.push('ship_status=ship without accepted phase');
  return { ok: errors.length === 0, errors };
}

function main() {
  const command = process.argv[2];
  const args = parseArgs(process.argv.slice(3));
  if (!command) fail('Usage: companion-control.cjs <validate-pack|evals|route|canonical-hash|validate-contract|validate-result>');

  if (command === 'route') {
    const filePath = args.case;
    if (!filePath) fail('--case is required');
    console.log(JSON.stringify(route(readJson(filePath)), null, 2));
    return;
  }
  if (command === 'canonical-hash') {
    const filePath = args.file;
    if (!filePath) fail('--file is required');
    console.log(canonicalHash(readJson(filePath)));
    return;
  }
  if (command === 'validate-pack' || command === 'evals') {
    const repoRoot = path.resolve(args['repo-root'] || '.');
    const result = validatePack(repoRoot);
    for (const warning of result.warnings) console.warn(`WARN: ${warning}`);
    if (!result.ok) {
      for (const error of result.errors) console.error(`FAIL: ${error}`);
      process.exit(1);
    }
    console.log(`Companion pack validation passed. Golden cases: ${readJson(path.join(repoRoot, 'evals', 'companion', 'golden_cases.json')).cases.length}`);
    return;
  }
  if (command === 'validate-contract') {
    const projectRoot = path.resolve(args['project-root'] || '.');
    const result = validateContract(projectRoot);
    if (!result.ok) {
      for (const error of result.errors) console.error(`FAIL: ${error}`);
      process.exit(1);
    }
    console.log(`Phase contract validation passed. Hash: ${result.contract_hash}`);
    return;
  }
  if (command === 'validate-result') {
    const projectRoot = path.resolve(args['project-root'] || '.');
    const result = validateResult(projectRoot);
    if (!result.ok) {
      for (const error of result.errors) console.error(`FAIL: ${error}`);
      process.exit(1);
    }
    console.log('Phase result validation passed.');
    return;
  }
  fail(`Unknown command: ${command}`);
}

if (require.main === module) main();
module.exports = { route, canonicalHash, validatePack, validateContract, validateResult };
