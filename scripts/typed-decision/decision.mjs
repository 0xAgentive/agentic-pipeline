import { createHash } from 'node:crypto';

const BINDING_KEYS = ['project_id', 'turn_id', 'epoch', 'context_sha256'];
const COMMON_KEYS = ['schema_version', ...BINDING_KEYS, 'kind'];
const SHA256 = /^[a-f0-9]{64}$/;
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value) && [Object.prototype, null].includes(Object.getPrototypeOf(value));
const text = value => typeof value === 'string' && value.trim().length > 0 && !/[\u0000-\u001f\u007f]/.test(value);
const exactKeys = (value, keys) => record(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const validBinding = value => record(value) && text(value.project_id) && text(value.turn_id) && Number.isSafeInteger(value.epoch) && value.epoch >= 0 && typeof value.context_sha256 === 'string' && SHA256.test(value.context_sha256);
const sameBinding = (value, expected) => validBinding(value) && validBinding(expected) && BINDING_KEYS.every(key => value[key] === expected[key]);
const copyBinding = value => Object.fromEntries(BINDING_KEYS.map(key => [key, value?.[key]]));
const evidenceRefs = refs => Array.isArray(refs) && refs.length > 0 && refs.every(text) && new Set(refs).size === refs.length;

function validPacket(packet) {
  return exactKeys(packet, ['packet_id', 'artifact_id', 'file_name', 'sha256', 'byte_length']) &&
    text(packet.packet_id) && text(packet.artifact_id) &&
    typeof packet.file_name === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(packet.file_name) &&
    !/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(packet.file_name) &&
    typeof packet.sha256 === 'string' && SHA256.test(packet.sha256) &&
    Number.isSafeInteger(packet.byte_length) && packet.byte_length > 0;
}

/** Untrusted payload validation. Successful validation is never authority to act. */
export function validateDecision(input, expected) {
  const errors = [];
  if (!validBinding(expected)) errors.push('invalid_expected_binding');
  if (!record(input)) return { ok: false, errors: [...errors, 'decision_must_be_object'] };
  if (!sameBinding(input, expected)) errors.push('decision_binding_mismatch');
  if (input.schema_version !== 1) errors.push('unsupported_schema_version');
  const payloadKeys = {
    packet_ready: ['packet'], still_working: ['reason'],
    owner_decision_required: ['question', 'blocking_scope'],
    completed: ['work_item_id', 'evidence_refs'],
    waiting_external: ['reason_code', 'reason'], context_reupload_required: ['reason'],
    failed: ['reason_code', 'reason']
  };
  if (!Object.hasOwn(payloadKeys, input.kind)) errors.push('unsupported_decision_kind');
  else if (!exactKeys(input, [...COMMON_KEYS, ...payloadKeys[input.kind]])) errors.push('unexpected_or_missing_fields');
  if (input.kind === 'packet_ready' && !validPacket(input.packet)) errors.push('invalid_packet');
  if (input.kind === 'still_working' && !text(input.reason)) errors.push('invalid_working_reason');
  if (input.kind === 'owner_decision_required' && (!text(input.question) || !['release', 'work_item'].includes(input.blocking_scope))) errors.push('invalid_owner_request');
  if (input.kind === 'completed' && (!text(input.work_item_id) || !evidenceRefs(input.evidence_refs))) errors.push('invalid_completion_claim');
  if (['waiting_external', 'context_reupload_required', 'failed'].includes(input.kind) && !text(input.reason)) errors.push('invalid_reason');
  if (input.kind === 'waiting_external' && !['quota_exhausted', 'tool_unavailable', 'transport_unavailable'].includes(input.reason_code)) errors.push('invalid_external_reason');
  if (input.kind === 'failed' && !['contract_invalid', 'input_invalid', 'execution_failed'].includes(input.reason_code)) errors.push('invalid_failure_reason');
  return errors.length ? { ok: false, errors } : { ok: true, decision: structuredClone(input), errors: [] };
}

function extractFirstJsonObject(str) {
  let depth = 0, inString = false, escape = false, start = -1;
  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    if (inString) {
      if (escape) escape = false;
      else if (ch === '\\') escape = true;
      else if (ch === '"') inString = false;
    } else {
      if (ch === '"') inString = true;
      else if (ch === '{') {
        if (depth === 0) start = i;
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0 && start !== -1) return str.slice(start, i + 1);
      }
    }
  }
  return str;
}

function parseJsonCandidate(body, expected) {
  try {
    const parsed = JSON.parse(body);
    if (!record(parsed) || parsed.schema_version !== 1 || typeof parsed.kind !== 'string') {
      return null;
    }
    const tokens = body.match(/"(?:\\.|[^"\\])*"|[{}\[\]:,]|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/g) || [];
    const stack = [];
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (token === '{') stack.push(new Set());
      else if (token === '[') stack.push(null);
      else if (token === '}' || token === ']') stack.pop();
      else if (token.startsWith('"') && tokens[i + 1] === ':') {
        const key = JSON.parse(token);
        const keys = stack.at(-1);
        if (!keys || keys.has(key)) return { ok: false, errors: ['duplicate_json_key'] };
        keys.add(key);
      }
    }
    return validateDecision(parsed, expected);
  } catch {
    return null;
  }
}

/** Only standalone JSON or explicitly labelled fence. Prose is never inferred. */
export function parseDecision(input, expected) {
  if (record(input)) return validateDecision(input, expected);
  if (typeof input !== 'string') return { ok: false, errors: ['decision_must_be_json'] };

  const rawCandidates = [];

  let direct = input.trim();
  if (/^companion_decision[ \t]*\r?\n/.test(direct)) {
    direct = direct.replace(/^companion_decision[ \t]*\r?\n/, '').trim();
  }
  rawCandidates.push(direct);

  const fenceRegex = /```(?:companion_decision|json)?[ \t]*\r?\n([\s\S]*?)(?:^```[ \t]*$|$)/gm;
  for (const match of input.matchAll(fenceRegex)) {
    const candidate = match[1].trim();
    if (candidate) rawCandidates.push(candidate);
  }

  const sig = '"schema_version"';
  let idx = input.indexOf(sig);
  while (idx !== -1) {
    const brace = input.lastIndexOf('{', idx);
    if (brace !== -1) {
      let d = 0, inStr = false, esc = false;
      for (let j = brace; j < input.length; j++) {
        const c = input[j];
        if (inStr) {
          if (esc) esc = false;
          else if (c === '\\') esc = true;
          else if (c === '"') inStr = false;
        } else {
          if (c === '"') inStr = true;
          else if (c === '{') d++;
          else if (c === '}') {
            d--;
            if (d === 0) {
              rawCandidates.push(input.slice(brace, j + 1).trim());
              break;
            }
          }
        }
      }
    }
    idx = input.indexOf(sig, idx + sig.length);
  }

  const validDecisions = [];
  const duplicateKeyErrors = [];
  const bindingErrors = [];

  for (const raw of rawCandidates) {
    const res = parseJsonCandidate(raw, expected);
    if (!res) continue;
    if (res.errors.includes('duplicate_json_key')) {
      duplicateKeyErrors.push(res);
      continue;
    }
    if (res.ok) {
      const serialized = JSON.stringify(res.decision);
      if (!validDecisions.some(d => JSON.stringify(d.decision) === serialized)) {
        validDecisions.push(res);
      }
    } else {
      bindingErrors.push(res);
    }
  }

  if (duplicateKeyErrors.length > 0 && validDecisions.length === 0) {
    return duplicateKeyErrors[0];
  }
  if (validDecisions.length >= 1) {
    if (validDecisions.length > 1) {
      console.warn(`[TypedDecision] Disambiguated ${validDecisions.length} valid decision blocks; selecting final block: ${validDecisions.at(-1).decision?.packet?.packet_id || validDecisions.at(-1).decision?.kind}`);
    }
    return validDecisions.at(-1);
  }
  if (bindingErrors.length > 0) {
    return bindingErrors[0];
  }

  return { ok: false, errors: ['invalid_json'] };
}


/** Pure byte check; caller must read the actual completed local file and retain it. */
export function verifyArtifactBytes(bytes, packet, binding) {
  const errors = [];
  if (!validBinding(binding)) errors.push('invalid_binding');
  if (!validPacket(packet)) errors.push('invalid_packet');
  if (!(bytes instanceof Uint8Array)) errors.push('bytes_required');
  const sha256 = bytes instanceof Uint8Array ? createHash('sha256').update(bytes).digest('hex') : null;
  const byte_length = bytes instanceof Uint8Array ? bytes.byteLength : null;
  if (validPacket(packet) && (sha256 !== packet.sha256 || byte_length !== packet.byte_length)) errors.push('artifact_bytes_mismatch');
  return { ...copyBinding(binding), artifact_id: packet?.artifact_id ?? null, expected_sha256: packet?.sha256 ?? null, sha256, byte_length, ok: errors.length === 0, errors };
}

/** Runtime facts MUST come from trusted local verifiers/receipt stores, never model JSON. */
export function deriveTruth(input, expected, runtimeFacts = {}) {
  const truth = { artifact: 'unverified', bridge: 'not_observed', execution: 'not_observed', acceptance: 'not_evaluated', release: 'not_evaluated', errors: [] };
  const checked = validateDecision(input, expected);
  if (!checked.ok) { truth.errors.push(...checked.errors); return truth; }
  if (!record(runtimeFacts)) { truth.errors.push('invalid_runtime_facts'); return truth; }
  const d = checked.decision;
  const readFact = (name, idKey, id, outcomes, requireRefs = false) => {
    const fact = runtimeFacts[name];
    if (fact === undefined) return null;
    const keys = [...BINDING_KEYS, idKey, 'outcome', 'receipt_id', ...(requireRefs ? ['evidence_refs'] : [])];
    if (!exactKeys(fact, keys) || !sameBinding(fact, expected) || fact[idKey] !== id || !text(fact.receipt_id) || !outcomes.includes(fact.outcome) || (requireRefs && (!evidenceRefs(fact.evidence_refs) || !d.evidence_refs.every(ref => fact.evidence_refs.includes(ref))))) {
      truth.errors.push(`invalid_or_unrelated_${name}`); return null;
    }
    return fact;
  };
  if (d.kind === 'packet_ready') {
    const v = runtimeFacts.artifact_verification;
    if (v !== undefined) {
      if (!exactKeys(v, [...BINDING_KEYS, 'artifact_id', 'expected_sha256', 'sha256', 'byte_length', 'ok', 'errors']) || !sameBinding(v, expected) || v.artifact_id !== d.packet.artifact_id || v.expected_sha256 !== d.packet.sha256 || typeof v.ok !== 'boolean' || !Array.isArray(v.errors)) truth.errors.push('invalid_or_unrelated_artifact_verification');
      else if (v.ok === false) truth.artifact = 'failed';
      else if (v.sha256 === d.packet.sha256 && v.byte_length === d.packet.byte_length && v.errors.length === 0) truth.artifact = 'verified';
      else truth.errors.push('inconsistent_artifact_verification');
    }
    const bridge = readFact('bridge_receipt', 'packet_id', d.packet.packet_id, ['accepted', 'rejected']);
    if (bridge) truth.bridge = bridge.outcome;
  }
  if (d.kind === 'completed') {
    const execution = readFact('execution_receipt', 'work_item_id', d.work_item_id, ['running', 'succeeded', 'failed']);
    const acceptance = readFact('acceptance_receipt', 'work_item_id', d.work_item_id, ['passed', 'failed'], true);
    const release = readFact('release_receipt', 'work_item_id', d.work_item_id, ['accepted', 'rejected'], true);
    if (execution) truth.execution = execution.outcome;
    if (acceptance) truth.acceptance = acceptance.outcome;
    if (release) truth.release = release.outcome;
  }
  return truth;
}

/** Advisory result only: owns no state, retry, timer, pause, process, network or UI. */
export function planDecision(input, expected, observation, runtimeFacts = {}) {
  const checked = validateDecision(input, expected);
  const truth = deriveTruth(input, expected, runtimeFacts);
  const result = { actionable: false, action: 'observe_only', keep_generation_running: true, truth, errors: [...checked.errors] };
  if (!checked.ok) return result;
  if (!sameBinding(observation, expected) || observation.after_current_user !== true || !text(observation.assistant_message_id)) {
    result.errors.push('uncorrelated_assistant_observation'); return result;
  }
  if (observation.generation_complete !== true) return result;
  const d = checked.decision;
  if (d.kind === 'still_working') return result;
  if (d.kind === 'waiting_external') return { ...result, action: 'await_external' };
  if (d.kind === 'context_reupload_required') return { ...result, actionable: true, action: 'context_needed_for_existing_policy' };
  if (d.kind === 'failed') return { ...result, actionable: true, action: 'failure_for_existing_policy' };
  if (d.kind === 'owner_decision_required') return { ...result, actionable: true, action: 'owner_request_for_existing_policy' };
  if (d.kind === 'packet_ready') {
    if (truth.artifact === 'verified' && truth.bridge !== 'rejected' && truth.errors.length === 0) return { ...result, actionable: true, action: truth.bridge === 'accepted' ? 'packet_already_accepted' : 'packet_available_for_existing_ingress' };
    return { ...result, action: 'await_artifact_verification' };
  }
  if (truth.execution === 'succeeded' && truth.acceptance === 'passed' && truth.errors.length === 0) return { ...result, actionable: true, action: 'work_item_completion_verified' };
  return { ...result, action: 'await_completion_evidence' };
}
