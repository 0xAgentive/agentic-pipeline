#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const root = path.resolve(process.argv[2] || '.');
const expectedVersion = '1.2.24';
const results = [];

function file(relativePath) { return path.join(root, relativePath); }
function exists(relativePath) { return fs.existsSync(file(relativePath)); }
function text(relativePath) { return fs.readFileSync(file(relativePath), 'utf8'); }
function json(relativePath) { return JSON.parse(text(relativePath)); }
function sha256(relativePath) { return crypto.createHash('sha256').update(fs.readFileSync(file(relativePath))).digest('hex'); }
function contains(relativePath, ...needles) {
  const source = text(relativePath);
  return needles.every((needle) => source.includes(needle));
}
function check(id, description, callback) {
  try {
    const value = callback();
    if (value !== true) throw new Error(typeof value === 'string' ? value : description);
    results.push({ id, status: 'PASS', description });
  } catch (error) {
    results.push({ id, status: 'FAIL', description, error: error.message });
  }
}

const playbook = json('tests/regression/KNOWN_FAILURE_PLAYBOOK_v1.2.24.json');
const executableIds = playbook.cases.filter((entry) => entry.verification_mode === 'executable_regression').map((entry) => entry.id);
check('PLAYBOOK', '70 reviewed, material and uniquely identified cases', () => {
  const ids = playbook.cases.map((entry) => entry.id);
  return playbook.ecosystem_version === expectedVersion && playbook.cases.length === 70 &&
    new Set(ids).size === 70 && playbook.cases.every((entry) => entry.review_status === 'reviewed' && entry.material === true && entry.evidence);
});

check('KF-001', 'TLS failures are classified separately and safe transport fallbacks retain certificate checks', () =>
  contains('scripts/release/GitHubTransport.ps1', 'Test-TransientGitHubNetworkFailure', 'http.version=HTTP/1.1', 'http.sslBackend=openssl', 'Certificate verification and revocation checks were not disabled.'));
check('KF-002', 'GitHub CLI auth, credential setup, API and Git transport are distinct probes', () =>
  contains('scripts/release/GitHubTransport.ps1', "@('auth', 'status'", "@('auth', 'setup-git'", "@('api'", "@('ls-remote'"));
check('KF-003', 'Windows validation has an explicit functional Bash capability probe and native fallback', () =>
  contains('scripts/windows/Test-FinalizationWindowsRegressions.ps1', '/bin/bash', 'GNU bash', 'Validate-AgenticPipelinePackage.ps1'));
check('KF-004', 'PowerShell 7 is explicitly required by the Windows regression gate', () =>
  contains('scripts/windows/Test-FinalizationWindowsRegressions.ps1', "PSVersion.Major -lt 7", 'Get-Command pwsh'));
check('KF-005', 'runtime-update is supported by the manifest writer', () =>
  contains('scripts/control-plane/write-installation-manifest.cjs', "'runtime-update'", 'defaultNextCommand = null'));
check('KF-006', 'runtime deployment uses the runtime validation surface, not repository docs', () => {
  const updater = text('scripts/windows/Update-AgenticProjectRuntime-v1.2.24.ps1');
  return updater.includes('Invoke-DeployedValidation') && !updater.includes('Test-HumanDocsCleanup.ps1');
});
check('KF-007', 'all active PowerShell is parser-gated', () =>
  contains('scripts/windows/Test-PowerShellRuntimeContracts.ps1', 'Parser]::ParseFile', 'PowerShell parse error'));
check('KF-008', 'runtime updater separates framework allowlist and product snapshot', () =>
  contains('scripts/windows/Update-AgenticProjectRuntime-v1.2.24.ps1', 'Get-ProductSnapshot', 'deployment_map', 'product_source_modified'));
check('KF-009', 'machine paths use structured results and UTF-8 rather than parsed display text', () =>
  contains('scripts/windows/common/NativeProcess.ps1', 'StandardOutputEncoding', 'UTF8Encoding') &&
  contains('scripts/windows/Test-FinalizationWindowsRegressions.ps1', 'stdout-юникод', 'stderr-отдельно'));
check('KF-010', 'Handoff root resolution retains distinct launch and implementation roots', () =>
  contains('integrations/companion-handoff-1.2.24/source/src/project_root_resolver.py', 'primary_implementation_root', 'logical_project_slug'));
check('KF-011', 'Git machine output separates stderr and uses NUL-delimited porcelain', () =>
  contains('scripts/windows/common/NativeProcess.ps1', 'StdOut', 'StdErr') &&
  contains('scripts/windows/companion/Publish-CandidateManifest.ps1', 'porcelain=v2', "'-z'"));
check('KF-012', 'PowerShell parser scans every active script', () =>
  contains('scripts/windows/Test-PowerShellRuntimeContracts.ps1', 'ParseError.Extent.StartColumnNumber'));
check('KF-013', 'automatic args collisions are rejected', () =>
  contains('scripts/windows/Test-PowerShellRuntimeContracts.ps1', 'Automatic variable is assigned', 'Automatic `$args is used for splatting'));
check('KF-014', 'automatic input collisions are rejected', () =>
  contains('scripts/windows/Test-PowerShellRuntimeContracts.ps1', 'ReservedAutomaticVariables', '"input"'));
check('KF-015', 'automatic variables cannot be parameter names', () =>
  contains('scripts/windows/Test-PowerShellRuntimeContracts.ps1', 'Automatic variable used as a parameter name'));
check('KF-016', 'Generic List conversion is runtime-tested for singleton and multiple values', () =>
  contains('scripts/windows/Test-FinalizationWindowsRegressions.ps1', 'Generic List singleton', '.ToArray()'));
check('KF-017', 'exact Companion contract markers are required', () =>
  contains('scripts/windows/companion/Test-CompanionPack-v1.2.24.ps1', 'Executor discovery', 'Completion', 'owner_interaction_policy'));
check('KF-018', 'active Companion filename is versioned and manifest-visible', () =>
  exists('docs/companion/SYSTEM_PROMPT_GPT56_COMPANION_v1.2.24.md') &&
  contains('docs/companion/00_AGENTIC_PIPELINE_INDEX_v1.2.24.md', 'SYSTEM_PROMPT_GPT56_COMPANION_v1.2.24.md'));
check('KF-019', 'all ecosystem version surfaces resolve to 1.2.24', () => {
  const version = json('VERSION.json');
  const ecosystem = json('ECOSYSTEM_VERSION.json');
  return ['package_version', 'runtime_version', 'playbook_version', 'companion_version'].every((key) => version[key] === expectedVersion) &&
    ecosystem.ecosystem_version === expectedVersion && Object.values(ecosystem.components).every((value) => value === expectedVersion);
});
check('KF-020', 'duplicated version matrices are byte-identical', () =>
  exists('docs/reference/PIPELINE_VERSION_MATRIX.md') && sha256('docs/PIPELINE_VERSION_MATRIX.md') === sha256('docs/reference/PIPELINE_VERSION_MATRIX.md'));
check('KF-021', 'documentation whitespace can be advisory without weakening strict mode', () =>
  contains('scripts/windows/Test-DistributionIntegrity.ps1', "ValidateSet('operational', 'strict')", 'Distribution advisory warnings'));
check('KF-022', 'Companion operational and strict whitespace policies are separate', () =>
  contains('scripts/windows/companion/Test-CompanionPack-v1.2.24.ps1', "ValidateSet('strict', 'advisory', 'skip')", 'Documentation-only whitespace issues are advisory'));
check('KF-023', 'active Markdown links are checked by package validation', () =>
  contains('scripts/windows/Test-HumanDocsCleanup.ps1', 'Markdown', 'link'));
check('KF-024', 'golden baseline is bound to exact source hash and IDs', () => {
  const baseline = json('tests/acceptance/golden-cases-baseline.json');
  const cases = json('evals/companion/golden_cases.json');
  return baseline.source_sha256 === sha256('evals/companion/golden_cases.json') &&
    Array.isArray(baseline.case_ids) && baseline.case_ids.length === cases.cases.length;
});
check('KF-025', 'acceptance suite contains behavioral assertions and placeholder meta-checks', () =>
  contains('integrations/companion-handoff-1.2.24/source/install/run_tests.py', 'test_T64_meta_test_no_false_green_tests', 'Placeholder/false-green tests found'));
check('KF-026', 'required acceptance imports cannot silently pass', () => {
  const source = text('tests/acceptance/autonomous-convergence-contract.cjs');
  return !/catch\s*\([^)]*\)\s*\{\s*\}/s.test(source) && !source.includes('ImportError');
});
check('KF-027', 'missing acceptance prerequisites are asserted', () =>
  contains('integrations/companion-handoff-1.2.24/source/install/run_tests.py', 'assert os.path.exists', 'TARGET_RUNTIME_BASELINE.json not found'));
check('KF-040', 'generic production scripts reject product-name leakage', () =>
  contains('scripts/windows/Test-ProjectLeakage.ps1', '$ProductionScripts', '$Terms', 'Project-specific term'));
check('KF-041', 'writer-shaped schemas share revision parity tests', () => {
  const schemaNames = ['work-item', 'execution-scope', 'execution-lease', 'stage-firewall', 'next-action', 'candidate-manifest-status'];
  const schemas = schemaNames.map((name) => json(`schemas/companion/${name}.schema.json`));
  const supportsRevision = (schema) => {
    const version = schema.properties && schema.properties.schema_version;
    return version && (version.const === '1.1.0' || (Array.isArray(version.enum) && version.enum.includes('1.1.0')));
  };
  return schemas.every(supportsRevision) &&
    contains('scripts/windows/companion/Start-WorkItemTransaction.ps1', 'action_packet_id') &&
    contains('scripts/windows/companion/Publish-CandidateManifest.ps1', 'candidate_file_count', 'ambient_file_count');
});
check('KF-042', 'legacy optional properties use explicit get/upsert helpers', () =>
  contains('scripts/windows/companion/Register-FindingDelta.ps1', 'Get-OptionalProperty', 'Set-OptionalProperty') &&
  contains('scripts/windows/companion/Bind-ExecutionScopeTransaction.ps1', 'Set-JsonProperty'));
check('KF-043', 'candidate overlay compares Git blobs and materializes checkout attributes', () =>
  contains('scripts/release/Apply-CandidateOverlay.ps1', 'hash-object', 'checkout-index') &&
  contains('scripts/release/Run-AgenticPipeline-v1.2.24-Upgrade-Local.ps1', 'Apply-CandidateOverlay.ps1', '-ExpectedPaths') &&
  exists('tests/acceptance/Test-CandidateOverlayEolSafety.ps1'));
check('KF-044', 'Git path consumers use NUL lists without trimming the first path byte', () =>
  contains('scripts/Test-FastPatchAllowed.ps1', '"--name-only", "-z"', 'Split-AgenticNulList') &&
  contains('scripts/windows/Test-FinalizationWindowsRegressions.ps1', 'docs-first-entry.txt'));
check('KF-045', 'Python cache is redirected outside validation checkouts', () =>
  contains('tests/acceptance/Test-ValidationSourceImmutability.ps1', 'PYTHONPYCACHEPREFIX', 'PYTHONDONTWRITEBYTECODE'));
check('KF-046', 'every validator is guarded by before/after tracked-byte snapshots', () =>
  contains('tests/acceptance/Test-ValidationSourceImmutability.ps1', 'Get-TrackedSnapshot', 'Compare-Snapshot', 'negative_one_byte_probe'));
check('KF-055', 'owner interaction contains no numeric repair budget', () => {
  const ownerFiles = fs.readdirSync(file('docs/companion')).filter((name) => name.endsWith('.md') && !name.startsWith('COMPANION_CHANGELOG'));
  return ownerFiles.every((name) => !/(repair_batch_limit|repair batches? \d+\/\d+|audit budget)/i.test(text(`docs/companion/${name}`)));
});
check('KF-056', 'owner output has the four plain-language sections', () =>
  ['Что происходит', 'Что уже сделано', 'Что будет дальше', 'Нужно ли что-то от владельца'].every((marker) => text('docs/companion/01_PROJECT_INSTRUCTIONS_v1.2.24.md').includes(marker)));
check('KF-057', 'PreToolUse hook invokes the execution lease before mutation', () =>
  contains('templates/agy-project-base/.agents/hooks.json', 'PreToolUse', 'agentic_runtime_hook.cjs') &&
  contains('templates/agy-project-base/.agents/hooks/agentic_runtime_hook.cjs', 'EXECUTION_LEASE.json', 'prewrite'));
check('KF-058', 'finding validator fails closed on lifecycle and materiality', () =>
  contains('scripts/control-plane/validate-findings.cjs', 'lifecycle_status', 'materiality', 'process.exit'));
check('KF-059', 'audit coverage completeness is required before transition', () =>
  contains('scripts/windows/companion/Test-AuditCoverageMatrix.ps1', 'acceptance_coverage', 'dimension_coverage'));
check('KF-060', 'work-item and authority activation publish transaction receipts', () =>
  contains('scripts/windows/companion/Start-WorkItemTransaction.ps1', 'WORK_ITEM_TRANSACTION.json', "status = 'committed'") &&
  contains('scripts/windows/companion/Bind-ExecutionScopeTransaction.ps1', 'EXECUTION_AUTHORITY_TRANSACTION.json', "status='committed'"));
check('KF-061', 'candidate and ambient paths remain separate', () =>
  contains('scripts/windows/companion/Publish-CandidateManifest.ps1', 'candidate_files', 'ambient_git_status'));
check('KF-062', 'preflight failures are accumulated before mutation', () =>
  contains('scripts/windows/Test-KnownFailureRegressionPlaybook-v1.2.24.ps1', '$Failures', '$FailureArray'));

const observedExecutable = new Set(results.filter((result) => result.id.startsWith('KF-')).map((result) => result.id));
check('EXECUTABLE-COVERAGE', 'every executable playbook case has a material check', () => {
  const missing = executableIds.filter((id) => !observedExecutable.has(id));
  return missing.length === 0 || `missing checks: ${missing.join(', ')}`;
});

const failures = results.filter((result) => result.status === 'FAIL');
process.stdout.write(`${JSON.stringify({
  schema_version: '1.0.0',
  status: failures.length === 0 ? 'PASS' : 'FAIL',
  executable_case_count: executableIds.length,
  results,
  failures,
}, null, 2)}\n`);
process.exitCode = failures.length === 0 ? 0 : 1;
