#!/usr/bin/env node
'use strict';
const fs = require('fs');
const materiality = new Set(['product_blocker','verification_blocker','release_blocker','service_warning','cosmetic']);
const lifecycle = new Set(['open_confirmed','fixed_unverified','verified_resolved','deferred','accepted_risk','false_positive','superseded']);
const category = new Set(['safety','security_privacy','data_integrity','research_validity','reproducibility','delivery','observability','cosmetic']);
const severity = new Set(['blocker','high','medium','low','info']);
const phase = new Set(['current_phase_blocker','next_phase_requirement','deferred_debt','accepted_risk','false_positive','superseded']);
const ownerDecisionTypes = new Set(['scope_or_requirement_change','destructive_or_irreversible_action','release_or_publication','credentials_private_data_or_paid_access','material_risk_acceptance','normative_protocol_change','required_capability_unavailable']);
const allowed = new Set(['finding_id','title','category','severity','lifecycle_status','phase_classification','evidence','implementation_alignment_status','empirical_validation_status','production_use_status','notes','materiality','auto_repairable','owner_decision_required','owner_decision_type','origin','coverage_id','audit_cycle','repair_batch_id']);
function validateFinding(f) {
  const errors = [];
  if (!f || typeof f !== 'object' || Array.isArray(f)) return ['FINDING_NOT_OBJECT'];
  for (const key of Object.keys(f)) if (!allowed.has(key)) errors.push(`UNKNOWN_FIELD:${key}`);
  if (!f.finding_id) errors.push('FINDING_ID_MISSING');
  if (!f.title) errors.push('TITLE_MISSING');
  if (!category.has(f.category)) errors.push(`CATEGORY_INVALID:${f.category}`);
  if (!severity.has(f.severity)) errors.push(`SEVERITY_INVALID:${f.severity}`);
  if (!lifecycle.has(f.lifecycle_status)) errors.push(`LIFECYCLE_INVALID:${f.lifecycle_status}`);
  if (!phase.has(f.phase_classification)) errors.push(`PHASE_CLASSIFICATION_INVALID:${f.phase_classification}`);
  if (!materiality.has(f.materiality)) errors.push(`MATERIALITY_INVALID:${f.materiality}`);
  if (typeof f.auto_repairable !== 'boolean') errors.push('AUTO_REPAIRABLE_MISSING');
  if (typeof f.owner_decision_required !== 'boolean') errors.push('OWNER_DECISION_REQUIRED_MISSING');
  if (f.owner_decision_required === true) {
    if (!ownerDecisionTypes.has(f.owner_decision_type)) errors.push('OWNER_DECISION_TYPE_INVALID');
    if (f.auto_repairable === true) errors.push('AUTO_REPAIRABLE_CANNOT_REQUIRE_OWNER_DECISION');
  } else if (f.owner_decision_type != null) {
    errors.push('OWNER_DECISION_TYPE_WITHOUT_DECISION');
  }
  return errors;
}
function validateSet(input) {
  const findings = Array.isArray(input) ? input : (input && Array.isArray(input.findings) ? input.findings : null);
  const errors = [];
  if (!findings) return {ok:false,errors:['FINDING_ARRAY_MISSING']};
  const ids = new Set();
  for (const f of findings) {
    for (const error of validateFinding(f)) errors.push(`${f && f.finding_id || 'unknown'}:${error}`);
    if (f && f.finding_id) {
      if (ids.has(f.finding_id)) errors.push(`DUPLICATE_FINDING_ID:${f.finding_id}`);
      ids.add(f.finding_id);
    }
  }
  return {ok:errors.length===0,errors,count:findings.length};
}
if (require.main === module) {
  const input = JSON.parse(fs.readFileSync(0,'utf8') || '{}');
  const result = validateSet(input);
  process.stdout.write(`${JSON.stringify(result,null,2)}\n`);
  process.exitCode = result.ok ? 0 : 1;
}
module.exports = {validateFinding,validateSet};
