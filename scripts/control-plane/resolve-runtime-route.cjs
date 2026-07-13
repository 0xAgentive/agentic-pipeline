#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const VALID_STATUS_VOCABULARY = new Set([
  'specification_required',
  'planning_required',
  'implementation_ready',
  'implementation_in_progress',
  'awaiting_audit',
  'acceptance_blocked',
  'release_candidate_ready',
  'recovery_required',
  'unknown'
]);

function resolveRuntimeRoute(input) {
  const facts = input || {};
  const projectInventory = facts.project_inventory || {};
  const centralAdvisory = facts.central_inventory_advisory || {};
  const gitFacts = facts.git_facts || {};
  const stateFacts = facts.state_facts || {};
  const phaseContractFacts = facts.phase_contract_facts || {};
  const phaseResultFacts = facts.phase_result_facts || {};
  const acceptanceFacts = facts.acceptance_facts || {};
  const routingPolicy = facts.routing_policy || {};
  const requestedCommand = facts.requested_command !== undefined ? facts.requested_command : null;

  const errors = [];
  const staleReasons = [];

  // 1. Determine Inventory Source & Installed Commands
  let inventorySource = 'missing';
  let projectLocalCommands = new Set();
  let inventoryPath = projectInventory.inventory_path || null;
  let inventorySha256 = projectInventory.inventory_sha256 || null;

  if (projectInventory.commands && Array.isArray(projectInventory.commands)) {
    inventorySource = projectInventory.source || 'project_local';
    projectLocalCommands = new Set(
      projectInventory.commands.map(c => typeof c === 'string' ? c : c.command).filter(Boolean)
    );
  } else if (projectInventory.source === 'advisory_only') {
    inventorySource = 'advisory_only';
  }

  const installedProjectVersion = projectInventory.runtime_version || stateFacts.runtime_version || 'unknown';
  const availablePipelineVersion = centralAdvisory.runtime_version || '1.2.0';

  // 2. Compatibility check
  let runtimeCompatibility = 'unknown';
  if (installedProjectVersion !== 'unknown' && availablePipelineVersion !== 'unknown') {
    if (installedProjectVersion === availablePipelineVersion) {
      runtimeCompatibility = 'compatible';
    } else if (routingPolicy.explicit_compatibility_matrix && routingPolicy.explicit_compatibility_matrix[installedProjectVersion] === availablePipelineVersion) {
      runtimeCompatibility = 'compatible';
    } else if (installedProjectVersion.startsWith('1.') && availablePipelineVersion.startsWith('1.')) {
      if (routingPolicy.allow_1x_compatibility === true) {
        runtimeCompatibility = 'compatible';
      }
    }
  }

  // Available commands from project-local ONLY
  const availableCommands = Array.from(projectLocalCommands).sort();

  for (const cmd of availableCommands) {
    if (typeof cmd !== 'string' || !cmd.startsWith('/') || cmd.trim() !== cmd) {
      errors.push(`Invalid available command format: '${cmd}'`);
    }
  }

  // Observed state-declared allowed commands
  const stateDeclaredAllowed = Array.isArray(stateFacts.commands_allowed_now)
    ? stateFacts.commands_allowed_now.filter(c => typeof c === 'string')
    : [];

  // 3. Compute Objective Stale Signals
  let isDirty = gitFacts.git_state === 'dirty' || gitFacts.is_dirty === true;
  let isStale = false;

  // Signal 1: Commit mismatch
  const resultCommit = phaseResultFacts.release_source_commit || phaseResultFacts.source_commit;
  if (resultCommit && gitFacts.head_commit && resultCommit !== gitFacts.head_commit) {
    isStale = true;
    staleReasons.push({
      code: 'PHASE_RESULT_COMMIT_MISMATCH',
      evidence: `Result commit (${resultCommit}) differs from HEAD commit (${gitFacts.head_commit})`,
      severity: 'error'
    });
  }

  // Signal 2: Contract hash mismatch
  if (phaseContractFacts.contract_hash && phaseResultFacts.contract_hash && phaseContractFacts.contract_hash !== phaseResultFacts.contract_hash) {
    isStale = true;
    staleReasons.push({
      code: 'PHASE_CONTRACT_HASH_MISMATCH',
      evidence: `Contract hash (${phaseContractFacts.contract_hash}) differs from result recorded hash (${phaseResultFacts.contract_hash})`,
      severity: 'error'
    });
  }

  // Signal 3: Inventory hash mismatch
  const priorInvHash = stateFacts.command_inventory_sha256 || phaseResultFacts.command_inventory_sha256;
  if (inventorySha256 && priorInvHash && inventorySha256 !== priorInvHash) {
    isStale = true;
    staleReasons.push({
      code: 'INVENTORY_HASH_MISMATCH',
      evidence: `Current inventory hash (${inventorySha256}) differs from prior recorded hash (${priorInvHash})`,
      severity: 'error'
    });
  }

  // Signal 4: Missing or invalid PHASE_RESULT
  if (phaseResultFacts.missing || phaseResultFacts.valid === false) {
    isStale = true;
    staleReasons.push({
      code: 'PHASE_RESULT_INVALID_OR_MISSING',
      evidence: 'Phase result is invalid or missing material evidence',
      severity: 'error'
    });
  }

  // Signal 5: Conflict between status and acceptance dimensions
  const rawStatus = stateFacts.current_status || stateFacts.phase_status || stateFacts.status || stateFacts.project_status;
  if (rawStatus === 'release_candidate_ready' || rawStatus === 'passed_release_acceptance') {
    if (acceptanceFacts.acceptance_status === 'blocked' ||
        acceptanceFacts.audit_status === 'failed' ||
        acceptanceFacts.verification_status === 'invalidated' ||
        acceptanceFacts.ship_status === 'NO_SHIP') {
      isStale = true;
      staleReasons.push({
        code: 'ACCEPTANCE_CONFLICT',
        evidence: `Status '${rawStatus}' conflicts with acceptance status (acceptance=${acceptanceFacts.acceptance_status}, ship=${acceptanceFacts.ship_status})`,
        severity: 'error'
      });
    }
  }

  // Signal 6: Tracked source modified after result commit
  if (gitFacts.source_changed_since_result === true) {
    isStale = true;
    staleReasons.push({
      code: 'SOURCE_CHANGED_AFTER_RESULT',
      evidence: 'Tracked product source modified after result source commit',
      severity: 'error'
    });
  }

  // Signal 7: Explicit stale flag
  if (stateFacts.stale_state === true || stateFacts.evidence_state === 'stale') {
    isStale = true;
    staleReasons.push({
      code: 'EXPLICIT_STALE_SIGNAL',
      evidence: 'State explicitly flagged as stale',
      severity: 'error'
    });
  }

  // Signal 8: Dirty Git while claiming release readiness
  if (isDirty && (rawStatus === 'release_candidate_ready' || rawStatus === 'passed_release_acceptance')) {
    isStale = true;
    staleReasons.push({
      code: 'DIRTY_GIT_RELEASE_CLAIM',
      evidence: 'Git is dirty while status claims release readiness',
      severity: 'error'
    });
  }

  // Status normalization
  let currentStatus = rawStatus && VALID_STATUS_VOCABULARY.has(rawStatus) ? rawStatus : (rawStatus ? 'unknown' : null);
  if (!currentStatus && stateFacts.current_phase) {
    currentStatus = 'unknown';
  }

  // 4. Compute Routing Mode & Recovery Commands
  let routingMode = 'normal';
  let resolvedAllowed = [];
  let nextRequiredCommand = null;

  if (inventorySource === 'missing' || inventorySource === 'advisory_only') {
    routingMode = 'invalid';
    errors.push('Project-local command inventory is missing, unreadable, or invalid in enforcing mode.');
  } else if (isDirty || isStale) {
    routingMode = 'recovery';

    const recoveryPolicyAllowlist = ['/landing', '/auditphase'];
    if (routingPolicy.allow_triage === true) {
      recoveryPolicyAllowlist.push('/triage');
    }

    // Intersect project_local_available_commands with recovery_policy_allowlist
    resolvedAllowed = recoveryPolicyAllowlist.filter(cmd => projectLocalCommands.has(cmd));

    // Recovery precedence:
    // 1. /landing
    // 2. /auditphase
    // 3. /triage
    if (projectLocalCommands.has('/landing')) {
      nextRequiredCommand = '/landing';
    } else if (projectLocalCommands.has('/auditphase')) {
      nextRequiredCommand = '/auditphase';
    } else if (routingPolicy.allow_triage === true && projectLocalCommands.has('/triage')) {
      nextRequiredCommand = '/triage';
    } else {
      nextRequiredCommand = null;
      errors.push('Recovery mode active but no recovery command (/landing, /auditphase) is installed in project-local inventory.');
    }
  } else if (currentStatus === 'unknown') {
    if (routingPolicy.allow_audit_on_unknown_status !== false && projectLocalCommands.has('/auditphase')) {
      routingMode = 'recovery';
      resolvedAllowed = ['/auditphase'].filter(cmd => projectLocalCommands.has(cmd));
      nextRequiredCommand = '/auditphase';
    } else {
      routingMode = 'invalid';
      errors.push('Unknown current_status in clean state cannot be routed safely.');
    }
  } else {
    routingMode = 'normal';

    if (stateDeclaredAllowed.length > 0) {
      resolvedAllowed = stateDeclaredAllowed.filter(cmd => projectLocalCommands.has(cmd));
    } else {
      resolvedAllowed = Array.from(projectLocalCommands);
    }

    nextRequiredCommand = stateFacts.next_required_command || null;
  }

  // 5. Evaluate Requested Command (if provided)
  let decision = 'no_executable_route';
  let decisionCommand = null;

  if (requestedCommand !== null) {
    if (typeof requestedCommand !== 'string' || requestedCommand.trim() === '') {
      decision = 'reject_unknown_command';
      decisionCommand = null;
      errors.push('Requested command is empty or whitespace-only.');
    } else if (!projectLocalCommands.has(requestedCommand)) {
      decision = 'reject_unknown_command';
      decisionCommand = null;
      errors.push(`Requested command '${requestedCommand}' is not installed in project-local inventory.`);
    } else {
      // Installed in project-local inventory
      if (routingMode === 'recovery') {
        const isImplementation = ['/nextphase', '/fastpatch', '/fixcritical', '/shipcheck', '/githubprepare', '/githubsync'].includes(requestedCommand);
        if (isImplementation || !resolvedAllowed.includes(requestedCommand)) {
          decision = 'fail_closed';
          decisionCommand = null;
          errors.push(`Requested command '${requestedCommand}' is blocked during recovery mode.`);
        } else {
          decision = 'route';
          decisionCommand = requestedCommand;
        }
      } else if (routingMode === 'normal') {
        if (resolvedAllowed.includes(requestedCommand)) {
          decision = 'route';
          decisionCommand = requestedCommand;
        } else {
          decision = 'fail_closed';
          decisionCommand = null;
          errors.push(`Requested command '${requestedCommand}' is not in resolved_commands_allowed_now.`);
        }
      } else {
        decision = 'fail_closed';
        decisionCommand = null;
      }
    }
  } else {
    if (routingMode === 'recovery') {
      if (nextRequiredCommand && resolvedAllowed.includes(nextRequiredCommand)) {
        decision = 'route';
        decisionCommand = nextRequiredCommand;
      } else {
        decision = 'fail_closed';
        decisionCommand = null;
      }
    } else if (routingMode === 'normal') {
      if (stateFacts.only_state_handoff && projectLocalCommands.has('/landing') && (resolvedAllowed.length === 0 || resolvedAllowed.includes('/landing'))) {
        decision = 'route';
        decisionCommand = '/landing';
      } else if (stateFacts.confirmed_blockers && projectLocalCommands.has('/fixcritical') && (resolvedAllowed.length === 0 || resolvedAllowed.includes('/fixcritical'))) {
        decision = 'route';
        decisionCommand = '/fixcritical';
      } else if (stateFacts.evidence_state === 'inconsistent' && projectLocalCommands.has('/auditphase') && (resolvedAllowed.length === 0 || resolvedAllowed.includes('/auditphase'))) {
        decision = 'route';
        decisionCommand = '/auditphase';
      } else if (nextRequiredCommand && resolvedAllowed.includes(nextRequiredCommand)) {
        decision = 'route';
        decisionCommand = nextRequiredCommand;
      } else {
        decision = 'no_executable_route';
        decisionCommand = null;
      }
    } else {
      decision = 'fail_closed';
      decisionCommand = null;
    }
  }

  // Invariant checks for routing_valid
  let routingValid = (routingMode !== 'invalid') && (errors.length === 0);

  if (inventorySource === 'missing' || inventorySource === 'advisory_only') {
    routingValid = false;
  }

  if (routingValid && routingMode === 'recovery') {
    if (!nextRequiredCommand || !resolvedAllowed.includes(nextRequiredCommand)) {
      routingValid = false;
      errors.push('Recovery mode active but next_required_command is not in resolved_commands_allowed_now.');
    }
    if (!currentStatus) {
      routingValid = false;
      errors.push('current_status is null or unpopulated.');
    }
  }

  return {
    routing_mode: routingMode,
    inventory_source: inventorySource,
    inventory_path: inventoryPath,
    inventory_sha256: inventorySha256,
    installed_project_runtime_version: installedProjectVersion,
    available_pipeline_runtime_version: availablePipelineVersion,
    runtime_compatibility: runtimeCompatibility,
    available_commands: availableCommands,
    state_declared_commands_allowed_now: stateDeclaredAllowed,
    resolved_commands_allowed_now: resolvedAllowed,
    commands_allowed_now: resolvedAllowed,
    next_required_command: nextRequiredCommand,
    current_status: currentStatus || 'unknown',
    stale_state: isStale,
    stale_reasons: staleReasons,
    routing_valid: routingValid,
    routing_errors: errors,
    decision: decision,
    command: decisionCommand
  };
}

if (require.main === module) {
  let inputData = '';
  const args = process.argv.slice(2);
  const fileArgIdx = args.indexOf('--facts-file');
  if (fileArgIdx !== -1 && args[fileArgIdx + 1]) {
    const factsPath = args[fileArgIdx + 1];
    inputData = fs.readFileSync(factsPath, 'utf8');
    const facts = JSON.parse(inputData);
    const decision = resolveRuntimeRoute(facts);
    console.log(JSON.stringify(decision, null, 2));
  } else {
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { inputData += chunk; });
    process.stdin.on('end', () => {
      try {
        const facts = JSON.parse(inputData || '{}');
        const decision = resolveRuntimeRoute(facts);
        console.log(JSON.stringify(decision, null, 2));
      } catch (err) {
        console.error('Invalid JSON input:', err.message);
        process.exit(1);
      }
    });
  }
}

module.exports = { resolveRuntimeRoute };
