import { parseDecision, validateDecision, planDecision } from './decision.mjs';

export function decisionInstruction(binding) {
  const probe = validateDecision({ schema_version: 1, ...binding, kind: 'still_working', reason: 'binding validation' }, binding);
  if (!probe.ok) throw new Error('invalid_binding');
  return '\n\nCOMPANION_BINDING:' + JSON.stringify(binding) + '\n' +
    'Return exactly one fenced companion_decision JSON block. Copy schema_version:1 and all COMPANION_BINDING fields exactly. ' +
    'Choose kind and only its fields: packet_ready {packet:{packet_id,artifact_id,file_name,sha256,byte_length}}; ' +
    'still_working {reason}; owner_decision_required {question,blocking_scope:"release"|"work_item"}; ' +
    'waiting_external {reason_code:"quota_exhausted"|"tool_unavailable"|"transport_unavailable",reason}; ' +
    'context_reupload_required {reason}; failed {reason_code:"contract_invalid"|"input_invalid"|"execution_failed",reason}. ' +
    'Use packet_ready only for an actual JSON file with measured SHA-256 and bytes. Use a portable ASCII .json filename. ' +
    'When choosing packet_ready, you MUST ALWAYS output the complete Agentic Action Packet JSON in a separate fenced ```json code block containing the matching packet_id in your response (even if you also generate the file in Python). ' +
    'All decision strings must be nonempty single-line values. If the previous audit or task is completed, immediately issue packet_ready with the Agentic Action Packet for the NEXT phase of product development (focusing strictly on business logic, core features, API contracts, and integration tests; do NOT generate installers, packaging, or standalone executable binaries until final release acceptance). ' +
    'Quota and tool availability do not require an owner decision. Do not insert local verifier or receipt fields into the decision.';
}

export function classifyBridgeDecision(input, binding, observation, facts = {}) {
  const parsed = parseDecision(input, binding);
  if (!parsed.ok) return { scenario: 'TYPED_WAIT', reason: parsed.errors.join(','), rawSummary: '' };
  const d = parsed.decision;
  const plan = planDecision(d, binding, observation, facts);
  const shared = { reason: plan.action, rawSummary: d.question || d.reason || '', decision: d, truth: plan.truth, whatNext: null, neededFromOwner: null };
  if (!plan.actionable) return { ...shared, scenario: 'TYPED_WAIT' };
  if (plan.action === 'owner_request_for_existing_policy') return { ...shared, scenario: 'OWNER_GATE', neededFromOwner: d.question };
  if (plan.action === 'context_needed_for_existing_policy') return { ...shared, scenario: 'CONTEXT_REUPLOAD_REQUIRED' };
  if (plan.action === 'failure_for_existing_policy') return { ...shared, scenario: 'COMPANION_BLOCKER' };
  if (plan.action === 'work_item_completion_verified') return { ...shared, scenario: 'TYPED_WORK_ITEM_COMPLETED' };
  // A packet is delivered only by the separate verified artifact ingress.
  return { ...shared, scenario: 'TYPED_WAIT' };
}
