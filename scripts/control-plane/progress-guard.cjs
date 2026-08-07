#!/usr/bin/env node
'use strict';
const fs = require('fs');
const crypto = require('crypto');

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    const output = {};
    for (const key of Object.keys(value).sort()) output[key] = stable(value[key]);
    return output;
  }
  return value;
}
function hash(value) {
  return crypto.createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
}
function isOpen(finding) {
  const status = String(finding.lifecycle_status || finding.status || 'open').toLowerCase();
  return !['verified_resolved','resolved','deferred','accepted_risk','superseded','false_positive'].includes(status);
}
function summarize(input = {}) {
  const findings = Array.isArray(input.findings) ? input.findings : [];
  const openProduct = findings.filter(f => isOpen(f) && f.materiality === 'product_blocker').map(f => String(f.finding_id)).sort();
  const openVerification = findings.filter(f => isOpen(f) && ['verification_blocker','release_blocker'].includes(f.materiality)).map(f => String(f.finding_id)).sort();
  const resolved = findings.filter(f => !isOpen(f)).map(f => String(f.finding_id)).sort();
  const tests = Array.isArray(input.tests) ? input.tests : [];
  const passingTests = tests.filter(t => Number(t.exit_code) === 0 || String(t.status).toLowerCase() === 'passed').length;
  const failingTests = tests.filter(t => Number(t.exit_code) !== 0 && t.exit_code !== undefined || ['failed','blocked'].includes(String(t.status).toLowerCase())).length;
  const checks = Array.isArray(input.acceptance_outcomes) ? input.acceptance_outcomes : [];
  const passedOutcomes = checks.filter(x => ['passed','accepted','complete','completed'].includes(String(x.status).toLowerCase())).length;
  const failedOutcomes = checks.filter(x => ['failed','blocked'].includes(String(x.status).toLowerCase())).length;
  return {
    open_product_ids: openProduct,
    open_verification_ids: openVerification,
    resolved_ids: resolved,
    passing_tests: passingTests,
    failing_tests: failingTests,
    passed_outcomes: passedOutcomes,
    failed_outcomes: failedOutcomes,
    product_state: input.product_state || null,
    route: input.route || null,
    failure_fingerprint: input.failure ? hash(input.failure) : null
  };
}
function strictlyImproved(previous, current, explicit) {
  if (explicit === true) return true;
  if (!previous) return true;
  return current.open_product_ids.length < previous.open_product_ids.length ||
    current.open_verification_ids.length < previous.open_verification_ids.length ||
    current.resolved_ids.length > previous.resolved_ids.length ||
    current.failing_tests < previous.failing_tests ||
    current.passing_tests > previous.passing_tests ||
    current.failed_outcomes < previous.failed_outcomes ||
    current.passed_outcomes > previous.passed_outcomes ||
    (previous.product_state !== current.product_state && current.product_state !== null);
}
function updateProgress(previous = {}, current = {}) {
  const now = new Date().toISOString();
  const metrics = summarize(current);
  const oldMetrics = previous.last_metrics || null;
  const progressed = strictlyImproved(oldMetrics, metrics, current.material_progress === true);
  const sameFailure = Boolean(metrics.failure_fingerprint && metrics.failure_fingerprint === previous.last_failure_fingerprint);
  const noProgress = progressed ? 0 : Number(previous.consecutive_no_progress || 0) + 1;
  const sameFailureCount = metrics.failure_fingerprint ? (sameFailure ? Number(previous.same_failure_count || 0) + 1 : 1) : 0;
  const stalled = noProgress >= 2 || sameFailureCount >= 2;
  const trueDecision = current.true_owner_decision_required === true;
  return {
    schema_version: '1.1.0',
    work_item_id: current.work_item_id || previous.work_item_id || null,
    status: stalled ? 'stalled' : (progressed ? 'progressing' : 'active'),
    observations_count: Number(previous.observations_count || previous.iteration_count || 0) + 1,
    consecutive_no_progress: noProgress,
    same_failure_count: sameFailureCount,
    last_failure_fingerprint: metrics.failure_fingerprint,
    last_metrics: metrics,
    last_progress_fingerprint: hash(metrics),
    last_material_change: progressed ? (current.material_change || now) : (previous.last_material_change || null),
    owner_decision_required: stalled && trueDecision,
    owner_decision_reason: stalled && trueDecision ? (current.owner_decision_reason || 'true_owner_decision_required') : null,
    updated_at_utc: now,
    history: [...(previous.history || []), {at_utc: now, progressed, consecutive_no_progress: noProgress, same_failure_count: sameFailureCount, metrics}].slice(-100)
  };
}
function routeFromProgress({state = {}, openFindings = []} = {}) {
  const product = openFindings.filter(f => isOpen(f) && f.materiality === 'product_blocker');
  const verification = openFindings.filter(f => isOpen(f) && ['verification_blocker','release_blocker'].includes(f.materiality));
  if (state.owner_decision_required === true) return {decision:'human_decision_required', route:null, reason:state.owner_decision_reason || 'true_owner_decision_required'};
  if (state.status === 'stalled') return {decision:'hard_stop', route:null, reason:'repeated_no_progress'};
  if (product.length) return {decision:'route', route:'/fixcritical', reason:'open_product_blockers'};
  if (verification.length) return {decision:'route', route:'/auditphase', reason:'verification_required'};
  return {decision:'route', route:'/auditphase', reason:'closure_verification'};
}
if (require.main === module) {
  const input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
  const result = input.action === 'route' ? routeFromProgress(input) : updateProgress(input.previous || {}, input.current || {});
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}
module.exports = {summarize, updateProgress, routeFromProgress};
