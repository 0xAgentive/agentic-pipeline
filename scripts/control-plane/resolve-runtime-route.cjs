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

const VALID_ASSURANCE_MODES = new Set(['flow', 'guarded', 'release']);
const ACTIVE_WORK_ITEM_STATUSES = new Set(['ready', 'active', 'implementation', 'repair', 'audit']);
const PRODUCT_COMMANDS = new Set(['/fixcritical', '/nextphase', '/fastpatch', '/auditphase']);
const PRODUCT_WRITE_COMMANDS = new Set(['/fixcritical', '/nextphase', '/fastpatch']);
const RELEASE_COMMANDS = new Set(['/shipcheck', '/githubprepare', '/githubsync']);

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

function countValue(value) {
  if (Array.isArray(value)) return value.length;
  if (Number.isFinite(Number(value))) return Math.max(0, Number(value));
  return 0;
}

function normalizeAssuranceMode(value) {
  const normalized = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return VALID_ASSURANCE_MODES.has(normalized) ? normalized : null;
}

function normalizeComparablePath(value) {
  if (typeof value !== 'string' || !value.trim()) return null;
  return value.trim().replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
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
  const workItemFacts = facts.work_item_facts || {};
  const runResultFacts = facts.run_result_facts || {};
  const executionScopeFacts = facts.execution_scope_facts || {};
  const flowPolicy = facts.flow_policy || {};

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
  const installedPackageVersion = installationFacts.installed_project_package_version || 'unknown';
  const installedRuntimeVersion = installationFacts.installed_project_runtime_version || 'unknown';
  const installedSourceCommit = installationFacts.installed_project_source_commit || 'unknown';
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

  const resultCommit = phaseResultFacts.release_source_commit || phaseResultFacts.source_commit || null;
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

  const priorInventoryHash = stateFacts.command_inventory_sha256 || phaseResultFacts.command_inventory_sha256 || null;
  if (inventorySha256 && priorInventoryHash && inventorySha256 !== priorInventoryHash) {
    addStale(
      'INVENTORY_HASH_MISMATCH',
      `Current inventory hash (${inventorySha256}) differs from prior recorded hash (${priorInventoryHash})`
    );
  }

  if (gitFacts.source_changed_since_result === true) {
    addStale('SOURCE_CHANGED_AFTER_RESULT', 'Tracked product source changed after the recorded result.', 'warning');
  }

  if (stateFacts.stale_state === true || stateFacts.evidence_state === 'stale') {
    addStale('EXPLICIT_STALE_SIGNAL', 'Project state explicitly declares stale evidence.');
  }

  if (stateFacts.evidence_state === 'inconsistent') {
    addStale('INCONSISTENT_EVIDENCE_SIGNAL', 'Project state explicitly declares inconsistent evidence.');
  }

  const phaseContractStructurallyValid = phaseContractFacts.structurally_valid !== false;
  if (phaseContractFacts.present === true && !phaseContractStructurallyValid) {
    addStale('PHASE_CONTRACT_SCHEMA_INVALID', 'The active phase contract is not schema-valid.', 'warning');
  }

  if (isDirty) {
    uniquePush(reasonCodes, 'DIRTY_GIT_PRESENT');
    uniquePush(reasonCodes, 'DIRTY_GIT_REQUIRES_RECOVERY');
  }

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
  const auditAuthoritative = auditFacts.audit_authoritative === true;
  const auditEvidenceComplete = auditFacts.audit_evidence_complete === true;
  const claimsEvidenceConsistent = auditFacts.claims_evidence_consistent === true;

  // Flow Restoration: a work item is stable authorization for one owner-approved goal.
  const workItemPresent = workItemFacts.present === true || Boolean(workItemFacts.work_item_id);
  const workItemStructurallyValid = workItemFacts.structurally_valid !== false && workItemPresent;
  const workItemId = workItemFacts.work_item_id || null;
  const rawGoalEpoch = workItemFacts.goal_epoch;
  const goalEpoch = (
    rawGoalEpoch !== null &&
    rawGoalEpoch !== undefined &&
    rawGoalEpoch !== '' &&
    Number.isInteger(Number(rawGoalEpoch)) &&
    Number(rawGoalEpoch) >= 1
  )
    ? Number(rawGoalEpoch)
    : null;
  const workItemStatus = typeof workItemFacts.status === 'string'
    ? workItemFacts.status.toLowerCase()
    : null;
  const ownerApproved = workItemFacts.owner_approved === true;
  const assuranceMode = normalizeAssuranceMode(
    workItemFacts.assurance_mode || flowPolicy.default_assurance_mode
  );
  const workItemActive =
    workItemStructurallyValid && ownerApproved && ACTIVE_WORK_ITEM_STATUSES.has(workItemStatus);
  const workItemCompleted = workItemStructurallyValid && workItemStatus === 'completed';
  const workItemArchived = workItemStructurallyValid && workItemStatus === 'archived';
  const scopeStatus = executionScopeFacts.status || workItemFacts.scope_status || 'unresolved';
  const scopeValid = executionScopeFacts.structurally_valid !== false && scopeStatus !== 'blocked';
  const workItemBranch = typeof workItemFacts.branch === 'string' ? workItemFacts.branch : null;
  const workItemProjectRoot = normalizeComparablePath(workItemFacts.project_root);
  const currentProjectRoot = normalizeComparablePath(gitFacts.git_root || facts.project_root);
  const branchMismatch = Boolean(workItemBranch && gitFacts.branch_name && workItemBranch !== gitFacts.branch_name);
  const projectRootMismatch = Boolean(workItemProjectRoot && currentProjectRoot && workItemProjectRoot !== currentProjectRoot);
  const scopeWorkItemMismatch = Boolean(
    executionScopeFacts.work_item_id && workItemId && executionScopeFacts.work_item_id !== workItemId
  );
  const externalDrift =
    executionScopeFacts.external_drift === true ||
    workItemFacts.external_drift === true ||
    branchMismatch ||
    projectRootMismatch ||
    scopeWorkItemMismatch;

  const flowRestorationEnabled = flowPolicy.enabled === true || workItemFacts.flow_restoration_enabled === true;
  const enforcementMode = ['shadow', 'enforcing'].includes(flowPolicy.enforcement_mode)
    ? flowPolicy.enforcement_mode
    : 'enforcing';
  const governanceDegraded = isDirty || isStale || !phaseContractStructurallyValid;
  const allowDegradedProductExecution = flowPolicy.allow_degraded_product_execution === true;
  const productLeaseAvailable =
    flowRestorationEnabled &&
    workItemActive &&
    assuranceMode !== null &&
    assuranceMode !== 'release' &&
    sourceTrustValid &&
    installedCommands.size > 0 &&
    runtimeCompatibility !== 'migration_required' &&
    scopeValid &&
    !externalDrift &&
    (!governanceDegraded || allowDegradedProductExecution);

  const runResultPresent = runResultFacts.present === true || Boolean(runResultFacts.work_item_id);
  const runResultStructurallyValid = runResultFacts.structurally_valid !== false && runResultPresent;
  const runResultMatchesWorkItem =
    !runResultPresent || !workItemId || runResultFacts.work_item_id === workItemId;
  const implementationStatus = runResultFacts.implementation_status || stateFacts.implementation_status || null;
  const verificationStatus = runResultFacts.verification_status || acceptanceFacts.verification_status || null;
  const runAuditStatus = runResultFacts.audit_status || acceptanceFacts.audit_status || null;
  const runAcceptanceStatus = runResultFacts.acceptance_status || acceptanceFacts.acceptance_status || null;

  const oldConfirmedBlockers =
    countValue(acceptanceFacts.open_confirmed_current_phase_blockers) +
    countValue(acceptanceFacts.repair_required_current_phase_findings) +
    (stateFacts.confirmed_blockers === true ? 1 : 0);
  const oldVerificationBlockers =
    countValue(acceptanceFacts.fixed_unverified_current_phase_findings) +
    countValue(acceptanceFacts.verification_required_current_phase_findings);

  // A fresh non-release work item owns its own blocker lifecycle. Legacy phase/findings
  // remain available for discovery, but they must not silently hijack the first route of
  // a newly owner-approved goal. Once a schema-valid RUN_RESULT exists for this work
  // item, that compact result becomes the routing authority for its blocker counts.
  // RELEASE work items and legacy projects without an active work item remain strict and
  // continue to consider the existing acceptance/findings surface.
  const currentRunResultApplies =
    runResultStructurallyValid &&
    runResultMatchesWorkItem &&
    (!workItemId || runResultFacts.work_item_id === workItemId);
  const useWorkItemScopedBlockers = workItemActive && assuranceMode !== 'release';

  const productBlockerCount = useWorkItemScopedBlockers
    ? (currentRunResultApplies ? countValue(runResultFacts.product_blockers) : 0)
    : Math.max(
        countValue(runResultFacts.product_blockers),
        countValue(acceptanceFacts.product_blockers),
        oldConfirmedBlockers
      );
  const verificationBlockerCount = useWorkItemScopedBlockers
    ? (currentRunResultApplies ? countValue(runResultFacts.verification_blockers) : 0)
    : Math.max(
        countValue(runResultFacts.verification_blockers),
        countValue(acceptanceFacts.verification_blockers),
        oldVerificationBlockers
      );
  const releaseBlockerCount = useWorkItemScopedBlockers
    ? (currentRunResultApplies ? countValue(runResultFacts.release_blockers) : 0)
    : Math.max(
        countValue(runResultFacts.release_blockers),
        countValue(acceptanceFacts.release_blockers)
      );
  const serviceWarningCount = useWorkItemScopedBlockers
    ? (currentRunResultApplies ? countValue(runResultFacts.service_warnings) : 0)
    : Math.max(
        countValue(runResultFacts.service_warnings),
        countValue(acceptanceFacts.service_warnings)
      );

  const hardStop =
    repairFacts.hard_stop === true ||
    workItemFacts.hard_stop === true ||
    runResultFacts.hard_stop === true;
  const noProgress =
    repairFacts.no_progress === true ||
    runResultFacts.no_progress === true ||
    (
      countValue(repairFacts.same_failure_count) >=
        countValue(flowPolicy.same_failure_limit || 3) &&
      repairFacts.progress_observed === false
    );
  const budgetExhausted = repairFacts.repair_budget_exhausted === true;
  const userOverride = repairFacts.user_continue_repair_authorized === true;

  let routingMode = 'normal';
  let resolvedAllowed = [];
  let nextRequiredCommand = null;
  let decision = 'no_executable_route';
  let decisionCommand = null;
  let terminalDecision = null;
  let hardFailure = false;
  let productExecutionAllowed = false;
  let releaseActionsAllowed = false;
  let governanceHealth = 'healthy';
  let ownerInteractionRequired = false;
  let shadowCandidateCommand = null;
  let shadowCandidateCommandsAllowed = [];

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
      '/nextphase': ['/auditphase', '/nextphase'],
      '/fastpatch': ['/auditphase', '/fastpatch']
    };
    resolvedAllowed = installedSubset(installedCommands, map[nextCommand] || []);
  }

  function resolveActiveProductWorkItem() {
    productExecutionAllowed = true;
    releaseActionsAllowed = false;
    routingMode = governanceDegraded ? 'degraded_product_execution' : assuranceMode;
    governanceHealth = routingMode === 'degraded_product_execution'
      ? 'degraded_non_blocking'
      : 'healthy';

    uniquePush(reasonCodes, 'OWNER_WORK_ITEM_AUTHORIZED');
    uniquePush(reasonCodes, `ASSURANCE_MODE_${assuranceMode.toUpperCase()}`);
    if (routingMode === 'degraded_product_execution') {
      uniquePush(reasonCodes, 'GOVERNANCE_METADATA_DEGRADED');
      uniquePush(reasonCodes, 'RELEASE_ACTIONS_CLOSED');
    }
    if (serviceWarningCount > 0) uniquePush(reasonCodes, 'SERVICE_WARNINGS_AUTO_RECONCILE');

    if (branchMismatch) uniquePush(reasonCodes, 'WORK_ITEM_BRANCH_MISMATCH');
    if (projectRootMismatch) uniquePush(reasonCodes, 'WORK_ITEM_PROJECT_ROOT_MISMATCH');
    if (scopeWorkItemMismatch) uniquePush(reasonCodes, 'EXECUTION_SCOPE_WORK_ITEM_MISMATCH');
    if (!runResultMatchesWorkItem) {
      errors.push('RUN_RESULT belongs to a different work item.');
      hardFailure = true;
      return;
    }
    if (runResultPresent && !runResultStructurallyValid) {
      errors.push('RUN_RESULT is present but structurally invalid.');
      hardFailure = true;
      return;
    }
    if (hardStop || noProgress) {
      ownerInteractionRequired = true;
      uniquePush(reasonCodes, hardStop ? 'HARD_STOP_REQUIRES_OWNER' : 'NO_PROGRESS_REQUIRES_OWNER');
      nextRequiredCommand = null;
      resolvedAllowed = [];
      return;
    }
    if (productBlockerCount > 0 || workItemStatus === 'repair') {
      uniquePush(reasonCodes, 'PRODUCT_BLOCKER_REQUIRES_REPAIR');
      requireCommand('/fixcritical', 'Product repair is required but /fixcritical is not installed.');
    } else if (verificationBlockerCount > 0 || workItemStatus === 'audit') {
      uniquePush(reasonCodes, 'VERIFICATION_BLOCKER_REQUIRES_AUDIT');
      requireCommand('/auditphase', 'Verification is required but /auditphase is not installed.');
    } else if (runResultStructurallyValid &&
               implementationStatus === 'completed' &&
               assuranceMode === 'guarded' &&
               runAuditStatus !== 'passed') {
      uniquePush(reasonCodes, 'GUARDED_AUDIT_REQUIRED');
      requireCommand('/auditphase', 'GUARDED work item requires /auditphase but it is not installed.');
    } else if (runResultStructurallyValid &&
               implementationStatus === 'completed' &&
               verificationStatus === 'passed' &&
               (assuranceMode === 'flow' || runAuditStatus === 'passed') &&
               productBlockerCount === 0 &&
               verificationBlockerCount === 0) {
      terminalDecision = 'work_item_completed';
      uniquePush(reasonCodes, 'WORK_ITEM_ACCEPTANCE_COMPLETE');
      nextRequiredCommand = null;
      resolvedAllowed = [];
    } else if (workItemFacts.preferred_command === '/fastpatch' && assuranceMode === 'flow') {
      uniquePush(reasonCodes, 'FLOW_FASTPATCH_READY');
      requireCommand('/fastpatch', 'FLOW work item prefers /fastpatch but it is not installed.');
    } else {
      uniquePush(reasonCodes, 'WORK_ITEM_IMPLEMENTATION_READY');
      requireCommand('/nextphase', 'Owner-approved work item is ready but /nextphase is not installed.');
    }

    if (nextRequiredCommand) setObjectiveAllowed(nextRequiredCommand);
    resolvedAllowed = resolvedAllowed.filter((command) => !RELEASE_COMMANDS.has(command));
  }

  if (!sourceTrustValid || installedCommands.size === 0 ||
      invalidInventoryCommands.length > 0 || duplicateInventoryCommands.length > 0) {
    routingMode = 'invalid';
    hardFailure = true;
  } else if (productLeaseAvailable) {
    resolveActiveProductWorkItem();
  } else if (workItemActive && flowRestorationEnabled && governanceDegraded && !allowDegradedProductExecution) {
    routingMode = 'recovery';
    governanceHealth = 'degraded_blocking_by_policy';
    uniquePush(reasonCodes, 'DEGRADED_PRODUCT_EXECUTION_DISABLED');
    resolvedAllowed = installedSubset(installedCommands, ['/auditphase', '/landing']);
    nextRequiredCommand = resolvedAllowed.includes('/auditphase') ? '/auditphase' : (resolvedAllowed[0] || null);
    if (!nextRequiredCommand) {
      errors.push('Governance is degraded and degraded product execution is disabled.');
      hardFailure = true;
    }
  } else if (workItemActive && flowRestorationEnabled && externalDrift) {
    routingMode = 'recovery';
    governanceHealth = 'invalidated_by_external_drift';
    uniquePush(reasonCodes, 'EXECUTION_LEASE_INVALIDATED_BY_EXTERNAL_DRIFT');
    resolvedAllowed = installedSubset(installedCommands, ['/auditphase', '/landing']);
    nextRequiredCommand = resolvedAllowed.includes('/auditphase') ? '/auditphase' : (resolvedAllowed[0] || null);
    if (!nextRequiredCommand) {
      errors.push('External drift invalidated the execution lease and no recovery command is installed.');
      hardFailure = true;
    }
  } else if (workItemActive && flowRestorationEnabled && assuranceMode === 'release') {
    // RELEASE remains on the strict legacy route and never uses degraded execution.
    routingMode = 'release';
    productExecutionAllowed = true;
    releaseActionsAllowed = true;
    governanceHealth = isDirty || isStale || !phaseContractStructurallyValid ? 'degraded_blocking_release' : 'healthy';
    if (isDirty || isStale || !phaseContractStructurallyValid) {
      resolvedAllowed = installedSubset(installedCommands, ['/auditphase', '/landing']);
      nextRequiredCommand = resolvedAllowed.includes('/auditphase') ? '/auditphase' : (resolvedAllowed[0] || null);
      uniquePush(reasonCodes, 'RELEASE_GOVERNANCE_REQUIRES_RECOVERY');
      if (!nextRequiredCommand) hardFailure = true;
    } else if (productBlockerCount > 0) {
      requireCommand('/fixcritical', 'Release work item has a product blocker but /fixcritical is not installed.');
    } else if (verificationBlockerCount > 0) {
      requireCommand('/auditphase', 'Release work item has a verification blocker but /auditphase is not installed.');
    } else if (releaseBlockerCount > 0) {
      requireCommand('/auditphase', 'Release work item has a release blocker but /auditphase is not installed.');
    } else if (runAcceptanceStatus === 'accepted' && runAuditStatus === 'passed' && verificationStatus === 'passed') {
      requireCommand('/shipcheck', 'Release work item is ready but /shipcheck is not installed.');
    } else {
      requireCommand('/nextphase', 'Release work item is not complete and /nextphase is not installed.');
    }
    if (nextRequiredCommand) setObjectiveAllowed(nextRequiredCommand);
  } else if (isDirty || isStale || currentStatus === 'recovery_required') {
    routingMode = 'recovery';
    governanceHealth = 'degraded_blocking';
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
      governanceHealth = 'unknown';
      resolvedAllowed = ['/auditphase'];
      nextRequiredCommand = '/auditphase';
    } else {
      routingMode = 'invalid';
      governanceHealth = 'invalid';
      errors.push('Unknown current_status in clean state cannot be routed safely.');
      hardFailure = true;
    }
  } else {
    routingMode = 'normal';
    governanceHealth = 'healthy';

    const stateHandoffRequired = stateFacts.state_handoff_required === true || stateFacts.only_state_handoff === true;
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

      if (authorityExplicitlyUnproven && productBlockerCount === 0) {
        uniquePush(reasonCodes, 'AWAITING_AUDIT');
        requireCommand('/auditphase', 'Audit authority is incomplete but /auditphase is not installed.');
      } else if (productBlockerCount > 0) {
        uniquePush(reasonCodes, 'CONFIRMED_BLOCKER_REQUIRES_REPAIR');
        if (budgetExhausted && !userOverride) {
          uniquePush(reasonCodes, 'REPAIR_BUDGET_EXHAUSTED');
          nextRequiredCommand = null;
          resolvedAllowed = [];
        } else {
          requireCommand('/fixcritical', 'Repair required but /fixcritical is not installed.');
        }
      } else if (verificationBlockerCount > 0) {
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
      const artifactsEligible = artifactStatus === null || artifactStatus === 'complete' || artifactStatus === 'not_required';
      const evidenceEligible =
        acceptancePassed &&
        auditPassed &&
        verificationPassed &&
        productBlockerCount === 0 &&
        verificationBlockerCount === 0 &&
        releaseBlockerCount === 0 &&
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
      resolvedAllowed = resolvedAllowed.filter((command) => !PRODUCT_WRITE_COMMANDS.has(command));
      if (nextRequiredCommand && PRODUCT_WRITE_COMMANDS.has(nextRequiredCommand)) {
        nextRequiredCommand = null;
      }
    }
  }

  // Shadow mode records the candidate route but never authorizes execution.
  if (enforcementMode === 'shadow' && productLeaseAvailable && nextRequiredCommand) {
    shadowCandidateCommand = nextRequiredCommand;
    shadowCandidateCommandsAllowed = [...resolvedAllowed];
    uniquePush(reasonCodes, 'FLOW_RESTORATION_SHADOW_MODE');
    productExecutionAllowed = false;
    releaseActionsAllowed = false;
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
      if (resolvedAllowed.includes(requested.root) && !PRODUCT_WRITE_COMMANDS.has(requested.root) && !RELEASE_COMMANDS.has(requested.root)) {
        decision = 'route';
        decisionCommand = requested.root;
      } else {
        decision = 'fail_closed';
        errors.push(`Requested command '${requested.root}' is blocked during recovery mode.`);
        hardFailure = true;
      }
    } else if (enforcementMode === 'shadow' && productLeaseAvailable) {
      if (shadowCandidateCommandsAllowed.includes(requested.root)) {
        decision = 'shadow_route';
        decisionCommand = null;
      } else {
        decision = 'fail_closed';
        errors.push(`Requested command '${requested.root}' is not available in the shadow candidate route.`);
        hardFailure = true;
      }
    } else if (routingMode === 'degraded_product_execution' && RELEASE_COMMANDS.has(requested.root)) {
      decision = 'fail_closed';
      errors.push(`Requested release command '${requested.root}' is blocked while governance health is degraded.`);
      hardFailure = true;
    } else if (!workItemActive && budgetExhausted && !userOverride && PRODUCT_WRITE_COMMANDS.has(requested.root)) {
      decision = 'human_decision_required';
      ownerInteractionRequired = true;
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
  } else if (terminalDecision === 'work_item_completed' || workItemCompleted) {
    decision = 'work_item_completed';
  } else if (workItemArchived) {
    decision = 'project_archived';
  } else if (routingMode === 'invalid') {
    decision = 'fail_closed';
    hardFailure = true;
  } else if (ownerInteractionRequired) {
    decision = 'human_decision_required';
  } else if (!workItemActive && productBlockerCount > 0 && budgetExhausted && !userOverride) {
    decision = 'human_decision_required';
    ownerInteractionRequired = true;
    uniquePush(reasonCodes, 'REPAIR_BUDGET_EXHAUSTED');
  } else if (enforcementMode === 'shadow' && productLeaseAvailable && shadowCandidateCommand) {
    decision = 'shadow_route';
    decisionCommand = null;
    nextRequiredCommand = null;
    resolvedAllowed = [];
  } else if (nextRequiredCommand && resolvedAllowed.includes(nextRequiredCommand)) {
    decision = 'route';
    decisionCommand = nextRequiredCommand;
  } else if (hardFailure) {
    decision = currentStatus === 'release_candidate_ready' || currentStatus === 'implementation_in_progress'
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
    claims_evidence_consistent: claimsEvidenceConsistent,
    flow_restoration_enabled: flowRestorationEnabled,
    enforcement_mode: enforcementMode,
    work_item_present: workItemPresent,
    work_item_structurally_valid: workItemStructurallyValid,
    work_item_id: workItemId,
    goal_epoch: goalEpoch,
    work_item_status: workItemStatus,
    assurance_mode: assuranceMode,
    execution_scope_status: scopeStatus,
    product_execution_allowed: productExecutionAllowed,
    release_actions_allowed: releaseActionsAllowed,
    governance_health: governanceHealth,
    owner_interaction_required: ownerInteractionRequired,
    product_blocker_count: productBlockerCount,
    verification_blocker_count: verificationBlockerCount,
    release_blocker_count: releaseBlockerCount,
    service_warning_count: serviceWarningCount,
    run_result_present: runResultPresent,
    run_result_structurally_valid: runResultStructurallyValid,
    shadow_candidate_command: shadowCandidateCommand,
    shadow_candidate_commands_allowed: shadowCandidateCommandsAllowed
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
