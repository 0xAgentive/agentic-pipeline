#!/usr/bin/env node
'use strict';

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

const IMPLEMENTATION_COMMANDS = new Set([
  '/fixcritical',
  '/nextphase',
  '/fastpatch',
  '/shipcheck',
  '/githubprepare',
  '/githubsync'
]);

function normalizeRootCommand(value) {
  if (value === null || value === undefined) {
    return { root: null, valid: true, supplied: false };
  }
  if (typeof value !== 'string') {
    return { root: null, valid: false, supplied: true, error: 'Requested command must be a string.' };
  }
  const trimmed = value.trim();
  if (!trimmed || !trimmed.startsWith('/')) {
    return {
      root: null,
      valid: false,
      supplied: true,
      error: 'Requested command is empty, whitespace-only, or does not start with /.'
    };
  }
  const match = trimmed.match(/^\/[^\s]+/);
  if (!match) {
    return { root: null, valid: false, supplied: true, error: 'Requested command has invalid syntax.' };
  }
  return { root: match[0], valid: true, supplied: true };
}

function normalizeInstalledCommand(value) {
  const raw = typeof value === 'string'
    ? value
    : (value && typeof value.command === 'string' ? value.command : null);
  if (raw === null) return null;
  const normalized = normalizeRootCommand(raw);
  if (!normalized.valid || normalized.root !== raw.trim()) return null;
  return normalized.root;
}

function uniquePush(array, value) {
  if (value && !array.includes(value)) array.push(value);
}

function installedSubset(installed, orderedCommands) {
  return orderedCommands.filter((command) => installed.has(command));
}

function hasPositiveNumber(value) {
  return Number.isFinite(Number(value)) && Number(value) > 0;
}

function resolveRuntimeRoute(input) {
  const facts = input || {};
  const projectInventory = facts.project_inventory || {};
  const installationFacts = facts.installation_facts || {};
  const centralAdvisory = facts.central_inventory_advisory || {};
  const gitFacts = facts.git_facts || {};
  const stateFacts = facts.state_facts || {};
  const phaseContractFacts = facts.phase_contract_facts || {};
  const phaseResultFacts = facts.phase_result_facts || {};
  const acceptanceFacts = facts.acceptance_facts || {};
  const auditFacts = facts.audit_facts || {};
  const repairFacts = facts.repair_facts || {};
  const routingPolicy = facts.routing_policy || {};

  const errors = [];
  const staleReasons = [];
  const reasonCodes = [];

  // Project-local inventory is the only command authority.
  const inventorySource = projectInventory.source || 'missing';
  const inventoryTrust = projectInventory.trust || 'none';
  const inventoryPath = projectInventory.inventory_path || null;
  const inventorySha256 = projectInventory.inventory_sha256 || null;

  const sourceTrustValid =
    (inventorySource === 'project_command_inventory' && inventoryTrust === 'authoritative') ||
    (inventorySource === 'project_workflow_directory_compat' && inventoryTrust === 'compatibility');

  const installedCommands = new Set();
  const invalidInventoryCommands = [];
  const duplicateInventoryCommands = [];

  if (Array.isArray(projectInventory.commands)) {
    for (const item of projectInventory.commands) {
      const command = normalizeInstalledCommand(item);
      if (!command) {
        invalidInventoryCommands.push(item);
        continue;
      }
      if (installedCommands.has(command)) duplicateInventoryCommands.push(command);
      installedCommands.add(command);
    }
  }

  if (!sourceTrustValid || installedCommands.size === 0 ||
      invalidInventoryCommands.length > 0 || duplicateInventoryCommands.length > 0) {
    uniquePush(reasonCodes, 'PROJECT_INVENTORY_MISSING');
    errors.push('Project-local command inventory is missing, unreadable, empty, or invalid in enforcing mode.');
    if (invalidInventoryCommands.length > 0) {
      errors.push('Project-local command inventory contains an invalid command entry.');
    }
    if (duplicateInventoryCommands.length > 0) {
      errors.push(`Project-local command inventory contains duplicate commands: ${[...new Set(duplicateInventoryCommands)].join(', ')}`);
    }
  }

  const availableCommands = [...installedCommands].sort();

  // Installation identity is intentionally separate from command inventory.
  const installationManifestPath = installationFacts.installation_manifest_path || null;
  const installationManifestSha256 = installationFacts.installation_manifest_sha256 || null;
  const installedPackageVersion =
    installationFacts.installed_project_package_version || 'unknown';
  const installedRuntimeVersion =
    installationFacts.installed_project_runtime_version || 'unknown';
  const installedSourceCommit =
    installationFacts.installed_project_source_commit || 'unknown';
  const availablePackageVersion = centralAdvisory.package_version || 'unknown';
  const availableRuntimeVersion = centralAdvisory.runtime_version || 'unknown';

  let runtimeCompatibility = 'unknown';
  if (installedRuntimeVersion === 'unknown' || availableRuntimeVersion === 'unknown') {
    runtimeCompatibility = 'unknown';
    uniquePush(reasonCodes, 'RUNTIME_IDENTITY_UNKNOWN');
  } else if (installedRuntimeVersion === availableRuntimeVersion) {
    runtimeCompatibility = 'compatible';
  } else {
    const matrix = routingPolicy.explicit_compatibility_matrix || {};
    if (matrix[installedRuntimeVersion] === availableRuntimeVersion) {
      runtimeCompatibility = 'compatible';
    } else {
      runtimeCompatibility = 'migration_required';
      uniquePush(reasonCodes, 'RUNTIME_MIGRATION_REQUIRED');
    }
  }

  const rawStatus =
    stateFacts.current_status ||
    stateFacts.phase_status ||
    stateFacts.status ||
    stateFacts.project_status ||
    null;
  const currentStatus = rawStatus && VALID_STATUS_VOCABULARY.has(rawStatus)
    ? rawStatus
    : (rawStatus ? 'unknown' : null);

  const requested = normalizeRootCommand(
    Object.prototype.hasOwnProperty.call(facts, 'requested_command')
      ? facts.requested_command
      : null
  );

  const gitState = gitFacts.git_state || (gitFacts.is_dirty === true ? 'dirty' : 'clean');
  const isDirty = gitState === 'dirty' || gitFacts.is_dirty === true;
  let isStale = false;

  function addStale(code, evidence, severity = 'error') {
    isStale = true;
    staleReasons.push({ code, evidence, severity });
    uniquePush(reasonCodes, 'OBJECTIVE_STALE_STATE');
  }

  const resultCommit =
    phaseResultFacts.release_source_commit ||
    phaseResultFacts.source_commit ||
    null;
  if (resultCommit && gitFacts.head_commit && resultCommit !== gitFacts.head_commit) {
    addStale(
      'PHASE_RESULT_COMMIT_MISMATCH',
      `Result commit (${resultCommit}) differs from HEAD commit (${gitFacts.head_commit})`
    );
  }

  if (phaseContractFacts.contract_hash && phaseResultFacts.contract_hash &&
      phaseContractFacts.contract_hash !== phaseResultFacts.contract_hash) {
    addStale(
      'PHASE_CONTRACT_HASH_MISMATCH',
      `Contract hash (${phaseContractFacts.contract_hash}) differs from result contract hash (${phaseResultFacts.contract_hash})`
    );
  }

  const priorInventoryHash =
    stateFacts.command_inventory_sha256 ||
    phaseResultFacts.command_inventory_sha256 ||
    null;
  if (inventorySha256 && priorInventoryHash && inventorySha256 !== priorInventoryHash) {
    addStale(
      'INVENTORY_HASH_MISMATCH',
      `Current inventory hash (${inventorySha256}) differs from prior recorded hash (${priorInventoryHash})`
    );
  }

  if (gitFacts.source_changed_since_result === true) {
    addStale('SOURCE_CHANGED_AFTER_RESULT', 'Tracked product source changed after the recorded result.');
  }

  if (stateFacts.stale_state === true || stateFacts.evidence_state === 'stale') {
    addStale('EXPLICIT_STALE_SIGNAL', 'Project state explicitly declares stale evidence.');
  }

  if (stateFacts.evidence_state === 'inconsistent') {
    addStale('INCONSISTENT_EVIDENCE_SIGNAL', 'Project state explicitly declares inconsistent evidence.');
  }

  if (isDirty) uniquePush(reasonCodes, 'DIRTY_GIT_REQUIRES_RECOVERY');

  const phaseResultPresent =
    phaseResultFacts.present !== undefined
      ? phaseResultFacts.present === true
      : (phaseResultFacts.missing !== true);
  const phaseResultStructurallyValid =
    phaseResultFacts.structurally_valid !== undefined
      ? phaseResultFacts.structurally_valid === true
      : (phaseResultFacts.valid !== false && phaseResultPresent);
  const phaseResultContractHashValid =
    phaseResultFacts.contract_hash_valid !== undefined
      ? phaseResultFacts.contract_hash_valid === true
      : (
          phaseResultPresent &&
          phaseContractFacts.contract_hash &&
          phaseResultFacts.contract_hash &&
          phaseContractFacts.contract_hash === phaseResultFacts.contract_hash
        );

  const auditResultPresent =
    auditFacts.audit_result_present !== undefined
      ? auditFacts.audit_result_present === true
      : phaseResultPresent;
  const auditResultStructurallyValid =
    auditFacts.audit_result_structurally_valid !== undefined
      ? auditFacts.audit_result_structurally_valid === true
      : (
          auditFacts.audit_result_schema_valid !== undefined
            ? auditFacts.audit_result_schema_valid === true
            : phaseResultStructurallyValid
        );
  const auditAuthoritative =
    auditFacts.audit_authoritative !== undefined
      ? auditFacts.audit_authoritative === true
      : false;
  const auditEvidenceComplete =
    auditFacts.audit_evidence_complete !== undefined
      ? auditFacts.audit_evidence_complete === true
      : false;
  const claimsEvidenceConsistent =
    auditFacts.claims_evidence_consistent !== undefined
      ? auditFacts.claims_evidence_consistent === true
      : false;

  const budgetExhausted = repairFacts.repair_budget_exhausted === true;
  const userOverride = repairFacts.user_continue_repair_authorized === true;
  const hasConfirmedBlockers =
    hasPositiveNumber(acceptanceFacts.open_confirmed_current_phase_blockers) ||
    hasPositiveNumber(acceptanceFacts.repair_required_current_phase_findings) ||
    stateFacts.confirmed_blockers === true;
  const hasFixedUnverified =
    hasPositiveNumber(acceptanceFacts.fixed_unverified_current_phase_findings) ||
    hasPositiveNumber(acceptanceFacts.verification_required_current_phase_findings);

  let routingMode = 'normal';
  let resolvedAllowed = [];
  let nextRequiredCommand = null;
  let decision = 'no_executable_route';
  let decisionCommand = null;
  let terminalDecision = null;
  let hardFailure = false;

  function requireCommand(command, missingMessage) {
    if (installedCommands.has(command)) {
      nextRequiredCommand = command;
      return true;
    }
    errors.push(missingMessage);
    hardFailure = true;
    nextRequiredCommand = null;
    return false;
  }

  function setObjectiveAllowed(nextCommand) {
    const map = {
      '/landing': ['/landing'],
      '/auditphase': ['/auditphase'],
      '/fixcritical': ['/auditphase', '/fixcritical'],
      '/shipcheck': ['/shipcheck'],
      '/specdoc': ['/specdoc'],
      '/planonly': ['/planonly'],
      '/nextphase': ['/auditphase', '/nextphase']
    };
    resolvedAllowed = installedSubset(installedCommands, map[nextCommand] || []);
  }

  if (!sourceTrustValid || installedCommands.size === 0 ||
      invalidInventoryCommands.length > 0 || duplicateInventoryCommands.length > 0) {
    routingMode = 'invalid';
    hardFailure = true;
  } else if (isDirty || isStale || currentStatus === 'recovery_required') {
    routingMode = 'recovery';
    if (currentStatus === 'recovery_required') uniquePush(reasonCodes, 'OBJECTIVE_STALE_STATE');
    resolvedAllowed = installedSubset(installedCommands, ['/landing', '/auditphase']);
    if (installedCommands.has('/landing')) {
      nextRequiredCommand = '/landing';
    } else if (installedCommands.has('/auditphase')) {
      nextRequiredCommand = '/auditphase';
    } else {
      errors.push('Recovery mode active but no recovery command (/landing or /auditphase) is installed.');
      hardFailure = true;
    }
  } else if (currentStatus === 'unknown' || currentStatus === null) {
    if (installedCommands.has('/auditphase')) {
      routingMode = 'recovery';
      resolvedAllowed = ['/auditphase'];
      nextRequiredCommand = '/auditphase';
    } else {
      routingMode = 'invalid';
      errors.push('Unknown current_status in clean state cannot be routed safely.');
      hardFailure = true;
    }
  } else {
    routingMode = 'normal';

    const stateHandoffRequired =
      stateFacts.state_handoff_required === true ||
      stateFacts.only_state_handoff === true;
    const landingCompleted = stateFacts.landing_completed === true;

    if (stateHandoffRequired && !landingCompleted) {
      uniquePush(reasonCodes, 'STATE_HANDOFF_REQUIRED');
      requireCommand('/landing', 'Handoff required but /landing is not installed in project-local inventory.');
    } else if (stateHandoffRequired && landingCompleted) {
      uniquePush(reasonCodes, 'LANDING_ALREADY_COMPLETED');
      requireCommand('/auditphase', 'Handoff completed but /auditphase is not installed.');
    } else if (currentStatus === 'specification_required') {
      uniquePush(reasonCodes, 'SPECIFICATION_REQUIRED');
      requireCommand('/specdoc', 'Status is specification_required but /specdoc is not installed.');
    } else if (currentStatus === 'planning_required') {
      uniquePush(reasonCodes, 'PLANNING_REQUIRED');
      requireCommand('/planonly', 'Status is planning_required but /planonly is not installed.');
    } else if (currentStatus === 'implementation_ready') {
      uniquePush(reasonCodes, 'IMPLEMENTATION_READY');
      requireCommand('/nextphase', 'Status is implementation_ready but /nextphase is not installed.');
    } else if (currentStatus === 'implementation_in_progress') {
      if (!phaseResultPresent || !phaseResultStructurallyValid) {
        uniquePush(reasonCodes, 'PHASE_RESULT_AUTHORITY_UNPROVEN');
        errors.push('Implementation is in progress but no structurally valid phase result proves a safe audit handoff.');
        hardFailure = true;
      } else {
        requireCommand('/auditphase', 'Implementation is in progress but /auditphase is not installed.');
      }
    } else if (currentStatus === 'awaiting_audit') {
      uniquePush(reasonCodes, 'AWAITING_AUDIT');
      requireCommand('/auditphase', 'Status is awaiting_audit but /auditphase is not installed.');
    } else if (currentStatus === 'acceptance_blocked') {
      const authorityExplicitlyUnproven =
        auditResultPresent === false ||
        auditResultStructurallyValid === false ||
        auditAuthoritative === false ||
        auditEvidenceComplete === false ||
        claimsEvidenceConsistent === false;

      if (authorityExplicitlyUnproven && !hasConfirmedBlockers) {
        uniquePush(reasonCodes, 'AWAITING_AUDIT');
        requireCommand('/auditphase', 'Audit authority is incomplete but /auditphase is not installed.');
      } else if (hasConfirmedBlockers) {
        uniquePush(reasonCodes, 'CONFIRMED_BLOCKER_REQUIRES_REPAIR');
        if (budgetExhausted && !userOverride) {
          uniquePush(reasonCodes, 'REPAIR_BUDGET_EXHAUSTED');
          nextRequiredCommand = null;
          resolvedAllowed = [];
        } else {
          requireCommand('/fixcritical', 'Repair required but /fixcritical is not installed.');
        }
      } else if (hasFixedUnverified) {
        uniquePush(reasonCodes, 'FIXED_UNVERIFIED_REQUIRES_AUDIT');
        requireCommand('/auditphase', 'Verification required but /auditphase is not installed.');
      } else {
        uniquePush(reasonCodes, 'AWAITING_AUDIT');
        requireCommand('/auditphase', 'No active blockers remain but /auditphase is not installed.');
      }
    } else if (currentStatus === 'release_candidate_ready') {
      const shipStatus = typeof acceptanceFacts.ship_status === 'string'
        ? acceptanceFacts.ship_status.toLowerCase()
        : null;

      const acceptancePassed =
        acceptanceFacts.acceptance_status === 'accepted' ||
        acceptanceFacts.acceptance_status === 'accepted_with_debt' ||
        acceptanceFacts.acceptance_status === 'passed';
      const auditPassed = acceptanceFacts.audit_status === 'passed';
      const verificationPassed = acceptanceFacts.verification_status === 'passed';
      const artifactStatus = acceptanceFacts.artifact_status || stateFacts.artifact_status || null;
      const artifactsEligible =
        artifactStatus === null ||
        artifactStatus === 'complete' ||
        artifactStatus === 'not_required';
      const evidenceEligible =
        acceptancePassed &&
        auditPassed &&
        verificationPassed &&
        !hasConfirmedBlockers &&
        artifactsEligible &&
        auditResultPresent !== false &&
        auditResultStructurallyValid !== false &&
        auditAuthoritative !== false &&
        auditEvidenceComplete !== false &&
        claimsEvidenceConsistent !== false;

      if (shipStatus === 'ship' && evidenceEligible) {
        terminalDecision = 'already_shipped';
        uniquePush(reasonCodes, 'FINAL_SHIP_DECISION_ALREADY_PRESENT');
      } else if (evidenceEligible) {
        uniquePush(reasonCodes, 'SHIPCHECK_ELIGIBLE');
        requireCommand('/shipcheck', 'Release candidate is eligible but /shipcheck is not installed.');
      } else {
        errors.push('Release claim made but required verification, audit, or acceptance evidence is incomplete.');
        hardFailure = true;
      }
    }

    if (nextRequiredCommand) setObjectiveAllowed(nextRequiredCommand);

    if (budgetExhausted && !userOverride) {
      resolvedAllowed = resolvedAllowed.filter((command) => !IMPLEMENTATION_COMMANDS.has(command));
      if (nextRequiredCommand && IMPLEMENTATION_COMMANDS.has(nextRequiredCommand)) {
        nextRequiredCommand = null;
      }
    }
  }

  // Requested-command authorization happens after objective routing.
  if (requested.supplied && !requested.valid) {
    decision = 'reject_unknown_command';
    decisionCommand = null;
    errors.push(requested.error);
    hardFailure = true;
  } else if (requested.supplied && requested.root && !installedCommands.has(requested.root)) {
    decision = 'reject_unknown_command';
    decisionCommand = null;
    errors.push(`Requested command '${requested.root}' is not installed in project-local inventory.`);
    hardFailure = true;
  } else if (requested.supplied && requested.root) {
    if (routingMode === 'invalid') {
      decision = 'fail_closed';
      hardFailure = true;
    } else if (routingMode === 'recovery') {
      if (resolvedAllowed.includes(requested.root) && !IMPLEMENTATION_COMMANDS.has(requested.root)) {
        decision = 'route';
        decisionCommand = requested.root;
      } else {
        decision = 'fail_closed';
        errors.push(`Requested command '${requested.root}' is blocked during recovery mode.`);
        hardFailure = true;
      }
    } else if (budgetExhausted && !userOverride && IMPLEMENTATION_COMMANDS.has(requested.root)) {
      decision = 'human_decision_required';
      uniquePush(reasonCodes, 'REPAIR_BUDGET_EXHAUSTED');
    } else if (resolvedAllowed.includes(requested.root)) {
      decision = 'route';
      decisionCommand = requested.root;
    } else {
      decision = 'fail_closed';
      errors.push(`Requested command '${requested.root}' is not in resolved_commands_allowed_now.`);
      hardFailure = true;
    }
  } else if (terminalDecision === 'already_shipped') {
    decision = 'already_shipped';
  } else if (routingMode === 'invalid') {
    decision = 'fail_closed';
    hardFailure = true;
  } else if (hasConfirmedBlockers && budgetExhausted && !userOverride) {
    decision = 'human_decision_required';
    uniquePush(reasonCodes, 'REPAIR_BUDGET_EXHAUSTED');
  } else if (nextRequiredCommand && resolvedAllowed.includes(nextRequiredCommand)) {
    decision = 'route';
    decisionCommand = nextRequiredCommand;
  } else if (hardFailure) {
    decision = currentStatus === 'release_candidate_ready' ||
      currentStatus === 'implementation_in_progress'
      ? 'fail_closed'
      : 'no_executable_route';
  } else {
    decision = 'no_executable_route';
  }

  let routingValid = sourceTrustValid && installedCommands.size > 0 && !hardFailure;
  if (decision === 'reject_unknown_command' || routingMode === 'invalid') routingValid = false;
  if (decision === 'fail_closed' && errors.length > 0) routingValid = false;

  return {
    routing_mode: routingMode,
    inventory_source: inventorySource,
    inventory_trust: inventoryTrust,
    inventory_path: inventoryPath,
    inventory_sha256: inventorySha256,
    inventory_command_count: availableCommands.length,
    installation_manifest_path: installationManifestPath,
    installation_manifest_sha256: installationManifestSha256,
    installed_project_package_version: installedPackageVersion,
    installed_project_runtime_version: installedRuntimeVersion,
    installed_project_source_commit: installedSourceCommit,
    available_pipeline_package_version: availablePackageVersion,
    available_pipeline_runtime_version: availableRuntimeVersion,
    runtime_compatibility: runtimeCompatibility,
    available_commands: availableCommands,
    state_declared_next_required_command: stateFacts.next_required_command || null,
    state_declared_commands_allowed_now: Array.isArray(stateFacts.commands_allowed_now)
      ? stateFacts.commands_allowed_now.filter((value) => typeof value === 'string')
      : [],
    resolved_commands_allowed_now: resolvedAllowed,
    commands_allowed_now: resolvedAllowed,
    next_required_command: nextRequiredCommand,
    current_status: currentStatus || 'unknown',
    stale_state: isStale,
    stale_reasons: staleReasons,
    routing_valid: routingValid,
    routing_errors: errors,
    routing_decision: decision,
    routing_reason_codes: reasonCodes,
    decision,
    command: decisionCommand,
    phase_result_present: phaseResultPresent,
    phase_result_structurally_valid: phaseResultStructurallyValid,
    phase_result_contract_hash_valid: phaseResultContractHashValid,
    audit_result_present: auditResultPresent,
    audit_result_structurally_valid: auditResultStructurallyValid,
    audit_authoritative: auditAuthoritative,
    audit_evidence_complete: auditEvidenceComplete,
    claims_evidence_consistent: claimsEvidenceConsistent
  };
}

if (require.main === module) {
  const fs = require('fs');
  const args = process.argv.slice(2);
  const factsIndex = args.indexOf('--facts-file');
  let inputText = '';

  if (factsIndex !== -1 && args[factsIndex + 1]) {
    inputText = fs.readFileSync(args[factsIndex + 1], 'utf8');
    const result = resolveRuntimeRoute(JSON.parse(inputText));
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { inputText += chunk; });
    process.stdin.on('end', () => {
      try {
        const result = resolveRuntimeRoute(JSON.parse(inputText || '{}'));
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      } catch (error) {
        console.error(`Invalid JSON input: ${error.message}`);
        process.exit(1);
      }
    });
  }
}

module.exports = {
  normalizeRootCommand,
  resolveRuntimeRoute
};
