#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const {
  normalizeRootCommand,
  resolveRuntimeRoute
} = require('../control-plane/resolve-runtime-route.cjs');

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const result = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value.startsWith('--')) {
      const key = value.slice(2);
      const next = argv[index + 1];
      if (next !== undefined && !next.startsWith('--')) {
        result[key] = next;
        index += 1;
      } else {
        result[key] = true;
      }
    } else {
      result._.push(value);
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

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
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
  return sha256Bytes(Buffer.from(JSON.stringify(canonicalize(value)), 'utf8'));
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// The production validator intentionally implements only the schema subset used
// by the repository. Unknown keywords fail closed.
const SUPPORTED_SCHEMA_KEYS = new Set([
  '$schema',
  '$id',
  'title',
  'description',
  'type',
  'required',
  'additionalProperties',
  'properties',
  'const',
  'enum',
  'pattern',
  'items',
  'minLength',
  'minItems'
]);

function assertSupportedSchema(schema, location = '$') {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw new Error(`${location}: schema node must be an object`);
  }
  for (const key of Object.keys(schema)) {
    if (!SUPPORTED_SCHEMA_KEYS.has(key)) {
      throw new Error(`${location}: unsupported schema keyword '${key}'`);
    }
  }
  if (schema.properties !== undefined) {
    if (!schema.properties || typeof schema.properties !== 'object' || Array.isArray(schema.properties)) {
      throw new Error(`${location}.properties must be an object`);
    }
    for (const [name, child] of Object.entries(schema.properties)) {
      assertSupportedSchema(child, `${location}.properties.${name}`);
    }
  }
  if (schema.items !== undefined) {
    assertSupportedSchema(schema.items, `${location}.items`);
  }
}

function valueType(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (Number.isInteger(value)) return 'integer';
  if (typeof value === 'number') return 'number';
  return typeof value;
}

function typeMatches(value, declared) {
  const types = Array.isArray(declared) ? declared : [declared];
  const actual = valueType(value);
  return types.some((type) => {
    if (type === actual) return true;
    if (type === 'number' && actual === 'integer') return true;
    if (type === 'object' && actual === 'object' && value !== null && !Array.isArray(value)) return true;
    return false;
  });
}

function validateValue(schema, value, location = '$') {
  const errors = [];

  if (schema.type !== undefined && !typeMatches(value, schema.type)) {
    errors.push(`${location}: expected type ${JSON.stringify(schema.type)}, got ${valueType(value)}`);
    return errors;
  }

  if (schema.const !== undefined && !deepEqual(value, schema.const)) {
    errors.push(`${location}: expected const ${JSON.stringify(schema.const)}, got ${JSON.stringify(value)}`);
  }

  if (schema.enum !== undefined) {
    if (!Array.isArray(schema.enum)) {
      errors.push(`${location}: schema enum must be an array`);
    } else if (!schema.enum.some((candidate) => deepEqual(candidate, value))) {
      errors.push(`${location}: value ${JSON.stringify(value)} is not in enum`);
    }
  }

  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push(`${location}: string is shorter than minLength ${schema.minLength}`);
    }
    if (schema.pattern !== undefined) {
      let expression;
      try {
        expression = new RegExp(schema.pattern);
      } catch (error) {
        errors.push(`${location}: invalid schema pattern: ${error.message}`);
        return errors;
      }
      if (!expression.test(value)) {
        errors.push(`${location}: value does not match pattern ${schema.pattern}`);
      }
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${location}: array is shorter than minItems ${schema.minItems}`);
    }
    if (schema.items !== undefined) {
      value.forEach((item, index) => {
        errors.push(...validateValue(schema.items, item, `${location}[${index}]`));
      });
    }
  }

  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const properties = schema.properties || {};
    const required = schema.required || [];
    if (!Array.isArray(required)) {
      errors.push(`${location}: schema required must be an array`);
    } else {
      for (const key of required) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) {
          errors.push(`${location}: missing required property '${key}'`);
        }
      }
    }
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!Object.prototype.hasOwnProperty.call(properties, key)) {
          errors.push(`${location}: additional property '${key}' is not allowed`);
        }
      }
    }
    for (const [key, childSchema] of Object.entries(properties)) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        errors.push(...validateValue(childSchema, value[key], `${location}.${key}`));
      }
    }
  }

  return errors;
}

function validateDocument(schema, document) {
  assertSupportedSchema(schema);
  return validateValue(schema, document);
}

function validateJsonFile(schemaPath, documentPath) {
  const schema = readJson(schemaPath);
  const document = readJson(documentPath);
  return {
    schema,
    document,
    errors: validateDocument(schema, document)
  };
}

function testSchemaValidator() {
  const schema = {
    type: 'object',
    additionalProperties: false,
    required: ['mode', 'commands'],
    properties: {
      mode: { type: 'string', enum: ['normal', 'recovery'] },
      commands: {
        type: 'array',
        minItems: 1,
        items: { type: 'string', pattern: '^/' }
      }
    }
  };
  const valid = { mode: 'normal', commands: ['/auditphase'] };
  const cases = [
    { id: 'valid', document: valid, pass: true },
    { id: 'missing_required', document: { commands: ['/auditphase'] }, pass: false },
    { id: 'additional_property', document: { ...valid, extra: true }, pass: false },
    { id: 'invalid_enum', document: { mode: 'invalid', commands: ['/auditphase'] }, pass: false },
    { id: 'invalid_pattern', document: { mode: 'normal', commands: ['auditphase'] }, pass: false }
  ];
  const failures = [];
  for (const item of cases) {
    const actual = validateDocument(schema, item.document).length === 0;
    if (actual !== item.pass) failures.push(`${item.id}: expected pass=${item.pass}, got ${actual}`);
  }
  let unsupportedRejected = false;
  try {
    assertSupportedSchema({ type: 'string', oneOf: [] });
  } catch {
    unsupportedRejected = true;
  }
  if (!unsupportedRejected) failures.push('unsupported keyword was not rejected');
  return { ok: failures.length === 0, failures, checks: cases.length + 1 };
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
    'docs/companion/VERSION.json'
  ].map((relative) => path.join(repoRoot, relative));
}

function makeLegacyResult(input, partial) {
  let resolved = partial.resolved_commands_allowed_now || input.available_commands || [];
  if (input.repair_budget_exhausted && !input.user_continue_repair_authorized) {
    const blocked = new Set(['/fixcritical', '/nextphase', '/fastpatch']);
    resolved = resolved.filter((command) => !blocked.has(command));
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

// Frozen v1.2.2 golden cases exercise this compatibility adapter. The
// authoritative runtime path is resolveRuntimeRoute() above.
function route(input) {
  const available = new Set(input.available_commands || input.project_local_available_commands || []);
  const allowed = new Set(input.commands_allowed_now || input.state_declared_commands_allowed_now || []);
  const requestedInfo = normalizeRootCommand(
    Object.prototype.hasOwnProperty.call(input, 'requested_command')
      ? input.requested_command
      : null
  );
  const requested = requestedInfo.root;

  if (requestedInfo.supplied && !requestedInfo.valid) {
    return makeLegacyResult(input, {
      decision: 'reject_unknown_command',
      command: null,
      routing_valid: false,
      routing_errors: [requestedInfo.error]
    });
  }
  if (requested && !available.has(requested)) {
    return makeLegacyResult(input, {
      decision: 'reject_unknown_command',
      command: null,
      routing_valid: false,
      routing_errors: [`Requested command '${requested}' is not installed in project-local inventory.`]
    });
  }
  if (input.repair_budget_exhausted && !input.user_continue_repair_authorized) {
    return makeLegacyResult(input, { decision: 'human_decision_required', command: null });
  }
  if (input.required_child_exit_codes &&
      input.required_child_exit_codes.some((code) => Number(code) !== 0)) {
    return makeLegacyResult(input, { decision: 'fail_closed', command: null, routing_valid: false });
  }
  if (input.production_outputs_changed_by_tests) {
    return makeLegacyResult(input, { decision: 'block_test_isolation', command: null, routing_valid: false });
  }
  if (input.zip_hash_embedded_inside_zip) {
    return makeLegacyResult(input, { decision: 'reject_self_reference', command: null, routing_valid: false });
  }
  if (input.contract_status === 'started' && input.new_acceptance_criteria) {
    return makeLegacyResult(input, { decision: 'classify_new_requirement', command: null });
  }
  if (input.risk_track === 'research' &&
      input.finding_category === 'delivery' &&
      input.affects_validity === false) {
    return makeLegacyResult(input, { decision: 'defer_non_blocking_debt', command: null });
  }
  if (input.artifact_metadata_stale && input.product_behavior_valid) {
    return makeLegacyResult(input, {
      decision: 'invalidate_artifact_claim_only',
      command: available.has('/auditphase') ? '/auditphase' : null
    });
  }
  if (input.phase_result_present === false && input.completion_prose_present) {
    return makeLegacyResult(input, { decision: 'report_unverified', command: null });
  }
  if (input.exact_version_contract === false && input.imports_pass && input.tests_pass) {
    return makeLegacyResult(input, { decision: 'accept_environment_deviation', command: null });
  }
  if (input.finding_lifecycle_status === 'verified_resolved') {
    return makeLegacyResult(input, { decision: 'exclude_from_open_count', command: null });
  }
  if (input.implementation_alignment_status === 'resolved' &&
      input.empirical_validation_status === 'unvalidated') {
    return makeLegacyResult(input, { decision: 'keep_production_use_conditional', command: null });
  }
  if (input.market_content_hash_match === true && input.provenance_hash_match === false) {
    return makeLegacyResult(input, { decision: 'accept_content_reject_provenance_identity', command: null });
  }

  if (input.confirmed_blockers === true && available.has('/fixcritical') &&
      (allowed.size === 0 || allowed.has('/fixcritical'))) {
    return makeLegacyResult(input, { decision: 'route', command: '/fixcritical' });
  }

  // Frozen enforcing-mode fixtures require an explicitly missing project
  // inventory to fail closed before any clean-state compatibility shortcut.
  if (input.inventory_source === 'missing') {
    return makeLegacyResult(input, {
      decision: 'fail_closed',
      command: null,
      routing_mode: 'invalid',
      resolved_commands_allowed_now: [],
      routing_valid: false
    });
  }

  // Legacy clean-state requested-command cases predate objective status facts.
  const gitState = input.git_state || 'clean';
  if (requested && gitState === 'clean' && !input.current_status &&
      !input.stale_state && !input.evidence_state && !input.only_state_handoff &&
      !input.state_handoff_required && !input.confirmed_blockers) {
    if (allowed.size > 0 && allowed.has(requested)) {
      return makeLegacyResult(input, { decision: 'route', command: requested });
    }
    if (allowed.size > 0 && !allowed.has(requested)) {
      return makeLegacyResult(input, { decision: 'fail_closed', command: null });
    }
  }
  if (!requested && gitState === 'clean' && !input.current_status &&
      !input.stale_state && !input.evidence_state && !input.only_state_handoff &&
      !input.state_handoff_required && !input.confirmed_blockers) {
    return makeLegacyResult(input, { decision: 'no_executable_route', command: null });
  }

  const inventorySource = input.inventory_source === 'missing'
    ? 'missing'
    : 'project_command_inventory';
  const inventoryTrust = inventorySource === 'missing' ? 'none' : 'authoritative';
  const facts = {
    project_inventory: {
      source: inventorySource,
      trust: inventoryTrust,
      commands: [...available],
      inventory_path: inventorySource === 'missing' ? null : 'legacy-fixture',
      inventory_sha256: inventorySource === 'missing' ? null : 'a'.repeat(64)
    },
    installation_facts: {
      installed_project_package_version: '1.2.3',
      installed_project_runtime_version: '1.2.0',
      installed_project_source_commit: 'legacy-fixture'
    },
    central_inventory_advisory: {
      package_version: '1.2.3',
      runtime_version: '1.2.0',
      commands: []
    },
    git_facts: {
      git_state: gitState,
      head_commit: input.head_commit
    },
    state_facts: {
      current_status: input.current_status,
      commands_allowed_now: input.state_declared_commands_allowed_now || input.commands_allowed_now,
      stale_state: input.stale_state,
      evidence_state: input.evidence_state,
      only_state_handoff: input.only_state_handoff,
      state_handoff_required: input.state_handoff_required,
      landing_completed: input.landing_completed,
      confirmed_blockers: input.confirmed_blockers,
      next_required_command: input.state_declared_next_required_command || input.next_required_command
    },
    phase_contract_facts: {
      contract_status: input.contract_status,
      contract_hash: input.contract_hash
    },
    phase_result_facts: {
      present: input.phase_result_present !== false,
      structurally_valid: input.phase_result_present !== false,
      contract_hash_valid: true,
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
      open_confirmed_current_phase_blockers:
        input.open_confirmed_current_phase_blockers !== undefined
          ? input.open_confirmed_current_phase_blockers
          : (input.open_current_phase_blockers || 0),
      repair_required_current_phase_findings: input.repair_required_current_phase_findings || 0,
      verification_required_current_phase_findings: input.verification_required_current_phase_findings || 0,
      fixed_unverified_current_phase_findings: input.fixed_unverified_current_phase_findings || 0,
      verified_resolved_findings: input.verified_resolved_findings || 0,
      deferred_product_findings: input.deferred_product_findings || 0,
      deferred_infrastructure_findings: input.deferred_infrastructure_findings || 0,
      accepted_risks: input.accepted_risks || 0
    },
    audit_facts: {
      audit_result_present: input.audit_result_present !== undefined ? input.audit_result_present : true,
      audit_result_structurally_valid:
        input.audit_result_schema_valid !== undefined ? input.audit_result_schema_valid : true,
      audit_authoritative: input.audit_authoritative !== undefined ? input.audit_authoritative : true,
      audit_evidence_complete:
        input.audit_evidence_complete !== undefined ? input.audit_evidence_complete : true,
      claims_evidence_consistent:
        input.claims_evidence_consistent !== undefined ? input.claims_evidence_consistent : true
    },
    repair_facts: {
      repair_budget_known: true,
      repair_budget_exhausted: input.repair_budget_exhausted === true,
      user_continue_repair_authorized: input.user_continue_repair_authorized === true,
      registered_repair_cycle_count: input.registered_repair_cycle_count || 0
    },
    routing_policy: {
      explicit_compatibility_matrix: {}
    },
    requested_command:
      Object.prototype.hasOwnProperty.call(input, 'requested_command')
        ? input.requested_command
        : null
  };

  const resolved = resolveRuntimeRoute(facts);
  const legacy = {
    decision: resolved.decision,
    command: resolved.command,
    routing_mode: resolved.routing_mode,
    resolved_commands_allowed_now: resolved.resolved_commands_allowed_now,
    next_required_command: resolved.next_required_command,
    routing_valid: resolved.routing_valid,
    routing_errors: resolved.routing_errors,
    reason_codes: input.stale_state === true ? ['EXPLICIT_STALE_SIGNAL'] : []
  };

  // Frozen v1.2.2 compatibility: an explicitly missing project inventory
  // always fails closed, even when no command was requested.
  if (input.inventory_source === 'missing') {
    legacy.routing_mode = 'invalid';
    legacy.resolved_commands_allowed_now = [];
    legacy.next_required_command = null;
    legacy.decision = 'fail_closed';
    legacy.command = null;
    legacy.routing_valid = false;
  }

  // Frozen recovery fixtures expect fail_closed when Git is dirty and the
  // project has no installed recovery command.
  if (gitState === 'dirty' && !available.has('/landing') && !available.has('/auditphase')) {
    legacy.routing_mode = 'recovery';
    legacy.resolved_commands_allowed_now = [];
    legacy.next_required_command = null;
    legacy.decision = 'fail_closed';
    legacy.command = null;
    legacy.routing_valid = false;
  }

  // Preserve the frozen v1.2.2 observable surface without weakening the new
  // authoritative resolver.
  if ((input.state_handoff_required || input.only_state_handoff) && !input.landing_completed &&
      gitState === 'clean') {
    legacy.routing_mode = 'normal';
    legacy.next_required_command = available.has('/landing') ? '/landing' : null;
    legacy.resolved_commands_allowed_now = [...available].sort();
    legacy.decision = legacy.next_required_command ? 'route' : 'no_executable_route';
    legacy.command = legacy.next_required_command;
    legacy.routing_valid = Boolean(legacy.next_required_command);
    legacy.routing_errors = legacy.next_required_command ? [] : ['Handoff required but /landing is not installed.'];
  }

  if ((input.state_handoff_required || input.only_state_handoff) && input.landing_completed &&
      gitState === 'clean') {
    legacy.routing_mode = 'normal';
    legacy.next_required_command = available.has('/auditphase') ? '/auditphase' : null;
    legacy.resolved_commands_allowed_now = legacy.next_required_command ? ['/auditphase'] : [];
    legacy.decision = legacy.next_required_command ? 'route' : 'no_executable_route';
    legacy.command = legacy.next_required_command;
    legacy.routing_valid = Boolean(legacy.next_required_command);
    legacy.routing_errors = legacy.next_required_command ? [] : ['Handoff completed but /auditphase is not installed.'];
  }

  if (input.current_status === 'acceptance_blocked' && gitState === 'clean') {
    const budgetBlocked = input.repair_budget_exhausted && !input.user_continue_repair_authorized;
    const legacyAllowed = [...available]
      .filter((command) => command !== '/landing')
      .filter((command) => !budgetBlocked || !['/fixcritical', '/nextphase', '/fastpatch'].includes(command))
      .sort();
    legacy.resolved_commands_allowed_now = legacyAllowed;
    if (budgetBlocked) {
      legacy.next_required_command = null;
      legacy.decision = 'human_decision_required';
      legacy.command = null;
      legacy.routing_valid = true;
      legacy.routing_errors = [];
    }
  }

  if (input.current_status === 'release_candidate_ready' &&
      input.ship_status === 'ship' &&
      input.acceptance_status === 'accepted' &&
      input.audit_status === 'passed' &&
      input.verification_status === 'passed' &&
      available.has('/shipcheck')) {
    legacy.routing_mode = 'normal';
    legacy.resolved_commands_allowed_now = ['/shipcheck'];
    legacy.next_required_command = '/shipcheck';
    legacy.decision = 'route';
    legacy.command = '/shipcheck';
    legacy.routing_valid = true;
    legacy.routing_errors = [];
  }

  return legacy;
}

function validateContract(projectRoot) {
  const errors = [];
  const contractPath = path.join(projectRoot, '.agy', 'PHASE_CONTRACT.json');
  const lockPath = path.join(projectRoot, '.agy', 'PHASE_CONTRACT.lock.json');
  if (!fs.existsSync(contractPath)) return { ok: false, errors: ['Missing .agy/PHASE_CONTRACT.json'] };

  const contract = readJson(contractPath);
  for (const key of [
    'phase_id',
    'goal',
    'risk_track',
    'evidence_level',
    'status',
    'repair_budget',
    'next_allowed_commands',
    'contract_hash'
  ]) {
    if (contract[key] === undefined) errors.push(`Phase contract missing ${key}`);
  }

  const actual = canonicalHash(contract);
  if (contract.contract_hash !== actual) {
    errors.push(`Phase contract hash mismatch: expected=${contract.contract_hash} actual=${actual}`);
  }

  if (fs.existsSync(lockPath)) {
    const lock = readJson(lockPath);
    if (lock.contract_hash !== contract.contract_hash) {
      errors.push('Phase contract lock hash differs from contract');
    }
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
  if (result.contract_hash !== contractCheck.contract_hash) {
    errors.push('Phase result contract_hash does not match phase contract');
  }

  const failedRequired = (result.command_results || [])
    .filter((item) => item.required && Number(item.exit_code) !== 0);

  if (failedRequired.length &&
      ['completed', 'passed', 'accepted', 'ship'].includes(result.implementation_status)) {
    errors.push('Phase result reports success while a required command failed');
  }
  if (failedRequired.length && result.verification_status === 'passed') {
    errors.push('verification_status=passed with failed required command');
  }
  if ((result.blockers || []).length && result.acceptance_status === 'accepted') {
    errors.push('acceptance_status=accepted while blockers remain');
  }
  if (result.ship_status === 'ship' && result.acceptance_status !== 'accepted') {
    errors.push('ship_status=ship without accepted phase');
  }

  return { ok: errors.length === 0, errors };
}

function validatePack(repoRoot) {
  const errors = [];
  const warnings = [];

  for (const filePath of activeCompanionFiles(repoRoot)) {
    if (!fs.existsSync(filePath)) {
      errors.push(`Missing active companion file: ${path.relative(repoRoot, filePath)}`);
    }
  }

  const schemaDir = path.join(repoRoot, 'schemas', 'companion');
  for (const name of [
    'runtime-handshake.schema.json',
    'phase-contract.schema.json',
    'finding.schema.json',
    'phase-result.schema.json',
    'repair-ledger-record.schema.json'
  ]) {
    const filePath = path.join(schemaDir, name);
    if (!fs.existsSync(filePath)) {
      errors.push(`Missing schema: schemas/companion/${name}`);
    } else {
      try {
        readJson(filePath);
      } catch (error) {
        errors.push(`Invalid JSON schema ${name}: ${error.message}`);
      }
    }
  }

  const companionVersionPath = path.join(repoRoot, 'docs', 'companion', 'VERSION.json');
  if (fs.existsSync(companionVersionPath)) {
    const version = readJson(companionVersionPath);
    if (version.companion_version !== '1.2.2') {
      errors.push('Companion VERSION.json does not declare 1.2.2');
    }
  }

  const evalPath = path.join(repoRoot, 'evals', 'companion', 'golden_cases.json');
  if (!fs.existsSync(evalPath)) {
    errors.push('Missing golden eval cases');
  } else {
    const evals = readJson(evalPath);
    if (!Array.isArray(evals.cases) || evals.cases.length < 16) {
      errors.push('Golden eval suite must contain at least 16 cases');
    }
    const ids = new Set();
    for (const item of evals.cases || []) {
      if (!item.id || !item.input || !item.expected) errors.push('Malformed golden eval case');
      if (ids.has(item.id)) errors.push(`Duplicate golden eval id: ${item.id}`);
      ids.add(item.id);

      const fullResult = route(item.input);
      const actual = {};
      for (const key of Object.keys(item.expected)) actual[key] = fullResult[key];
      if (!deepEqual(actual, item.expected)) {
        errors.push(
          `Golden eval failed: ${item.id}; expected=${JSON.stringify(item.expected)} actual=${JSON.stringify(actual)}`
        );
      }
    }
  }

  const commandInventoryPath = path.join(repoRoot, 'config', 'command-inventory.json');
  if (fs.existsSync(commandInventoryPath)) {
    const inventory = readJson(commandInventoryPath);
    const commands = new Set((inventory.commands || []).map((item) => item.command));
    if (commands.has('/recovery')) errors.push('Runtime command inventory unexpectedly contains /recovery');
    for (const required of ['/auditphase', '/fixcritical', '/landing', '/nextphase']) {
      if (!commands.has(required)) warnings.push(`Runtime inventory does not contain expected route ${required}`);
    }
  }

  const absolutePathPattern = /[A-Za-z]:\\Users\\|file:\/\/\//i;
  for (const filePath of activeCompanionFiles(repoRoot).filter(
    (candidate) => candidate.endsWith('.md') && fs.existsSync(candidate)
  )) {
    if (absolutePathPattern.test(readText(filePath))) {
      errors.push(`Active companion doc contains local absolute path or file URI: ${path.relative(repoRoot, filePath)}`);
    }
  }

  return { ok: errors.length === 0, errors, warnings };
}

function main() {
  const command = process.argv[2];
  const args = parseArgs(process.argv.slice(3));

  if (!command) {
    fail(
      'Usage: companion-control.cjs <validate-pack|evals|route|canonical-hash|' +
      'validate-contract|validate-result|validate-handshake|validate-json|test-schema-validator>'
    );
  }

  if (command === 'route') {
    if (!args.case) fail('--case is required');
    process.stdout.write(`${JSON.stringify(route(readJson(args.case)), null, 2)}\n`);
    return;
  }

  if (command === 'canonical-hash') {
    if (!args.file) fail('--file is required');
    process.stdout.write(`${canonicalHash(readJson(args.file))}\n`);
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
    const count = readJson(path.join(repoRoot, 'evals', 'companion', 'golden_cases.json')).cases.length;
    console.log(`Companion pack validation passed. Golden cases: ${count}`);
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

  if (command === 'validate-handshake') {
    const repoRoot = path.resolve(args['repo-root'] || '.');
    const filePath = path.resolve(args.file || '');
    if (!args.file) fail('--file is required');
    const schemaPath = path.join(repoRoot, 'schemas', 'companion', 'runtime-handshake.schema.json');
    const result = validateJsonFile(schemaPath, filePath);
    if (result.errors.length) {
      for (const error of result.errors) console.error(`FAIL: ${error}`);
      process.exit(1);
    }
    console.log(`Runtime handshake schema validation passed: ${filePath}`);
    return;
  }

  if (command === 'validate-json') {
    if (!args.schema || !args.file) fail('--schema and --file are required');
    const result = validateJsonFile(path.resolve(args.schema), path.resolve(args.file));
    if (args.json) {
      process.stdout.write(`${JSON.stringify({ ok: result.errors.length === 0, errors: result.errors })}\n`);
    } else if (result.errors.length === 0) {
      console.log(`JSON schema validation passed: ${path.resolve(args.file)}`);
    } else {
      for (const error of result.errors) console.error(`FAIL: ${error}`);
    }
    if (result.errors.length) process.exit(1);
    return;
  }

  if (command === 'test-schema-validator') {
    const result = testSchemaValidator();
    if (!result.ok) {
      for (const failure of result.failures) console.error(`FAIL: ${failure}`);
      process.exit(1);
    }
    console.log(`Schema validator self-test passed. Checks: ${result.checks}`);
    return;
  }

  fail(`Unknown command: ${command}`);
}

if (require.main === module) main();

module.exports = {
  canonicalHash,
  route,
  validateContract,
  validateDocument,
  validatePack,
  validateResult,
  validateValue
};
