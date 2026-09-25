#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
// Embedded contract: schemas/companion/action-packet.schema.json.
// SHA-256: 509ef172b1f79710bd28350ee2b2a46c63bf21f646366cc4b193bb27b817946e
// No runtime schema package or template-relative schema dependency.
const REQUIRED = ["schema_version", "ecosystem_version", "packet_id", "project_id", "operation", "route", "goal", "assurance_mode", "owner_approved", "owner_interaction_policy", "scope_binding", "technical_task_markdown", "owner_summary_ru", "created_at_utc", "expires_at_utc"];
const PROPERTIES = {
  "schema_version": {
    "const": "1.2.9"
  },
  "ecosystem_version": {
    "const": "1.2.27"
  },
  "packet_format": {
    "const": "single_json"
  },
  "packet_id": {
    "type": "string",
    "pattern": "^[A-Za-z0-9._-]{8,128}$"
  },
  "project_id": {
    "type": "string",
    "minLength": 1
  },
  "project_root_hint": {
    "type": [
      "string",
      "null"
    ]
  },
  "capability_token": {
    "type": "string",
    "pattern": "^[0-9a-f]{64}$",
    "writeOnly": true,
    "description": "Local-only field injected by Action Bridge after external validation; never exported by Companion."
  },
  "operation": {
    "enum": [
      "new_work_item",
      "continue_work_item"
    ]
  },
  "route": {
    "enum": [
      "/nextphase",
      "/fixcritical",
      "/auditphase",
      "/fastpatch",
      "/shipcheck"
    ]
  },
  "work_item_id": {
    "type": [
      "string",
      "null"
    ]
  },
  "goal_epoch": {
    "type": [
      "integer",
      "null"
    ],
    "minimum": 1
  },
  "goal": {
    "type": "string",
    "minLength": 1
  },
  "owner_goal_sha256": {
    "type": [
      "string",
      "null"
    ],
    "pattern": "^[0-9a-f]{64}$"
  },
  "assurance_mode": {
    "enum": [
      "flow",
      "guarded",
      "release"
    ]
  },
  "stage_profile": {
    "enum": [
      "general",
      "protocol_freeze",
      "analytical_validation",
      "empirical_validation"
    ]
  },
  "owner_approved": {
    "const": true
  },
  "owner_interaction_policy": {
    "const": "hard_stop_only"
  },
  "scope_binding": {
    "enum": [
      "executor_discovery",
      "exact"
    ]
  },
  "acceptance": {
    "type": "array",
    "items": {
      "type": "string"
    }
  },
  "non_goals": {
    "type": "array",
    "items": {
      "type": "string"
    }
  },
  "risk_hints": {
    "type": "array",
    "items": {
      "type": "string"
    }
  },
  "audit_dimensions": {
    "type": "object"
  },
  "technical_task_markdown": {
    "type": "string",
    "minLength": 1
  },
  "owner_summary_ru": {
    "type": "string",
    "minLength": 1
  },
  "created_at_utc": {
    "type": "string",
    "minLength": 1
  },
  "expires_at_utc": {
    "type": "string",
    "minLength": 1
  }
};
const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

function matchesType(value, type) {
  if (type === 'null') return value === null;
  if (type === 'array') return Array.isArray(value);
  if (type === 'object') return value !== null && typeof value === 'object' && !Array.isArray(value);
  if (type === 'integer') return Number.isInteger(value);
  return typeof value === type;
}
function validateSchemaValue(value, spec, pointer, errors) {
  if (hasOwn(spec, 'const') && value !== spec.const) errors.push(`SCHEMA_CONST:${pointer}`);
  if (spec.enum && !spec.enum.includes(value)) errors.push(`SCHEMA_ENUM:${pointer}`);
  if (spec.type && !(Array.isArray(spec.type) ? spec.type : [spec.type]).some(type => matchesType(value, type))) {
    errors.push(`SCHEMA_TYPE:${pointer}`);
    return;
  }
  if (typeof value === 'string') {
    if (spec.minLength !== undefined && Array.from(value).length < spec.minLength) errors.push(`SCHEMA_MIN_LENGTH:${pointer}`);
    // All pinned schema patterns are anchored identifiers. Require the complete
    // string to match, including no trailing newline accepted by JS's $ anchor.
    if (spec.pattern) {
      const match = new RegExp(spec.pattern).exec(value);
      if (!match || match[0] !== value) errors.push(`SCHEMA_PATTERN:${pointer}`);
    }
  }
  if (typeof value === 'number' && spec.minimum !== undefined && value < spec.minimum) errors.push(`SCHEMA_MINIMUM:${pointer}`);
  if (Array.isArray(value) && spec.items) value.forEach((item, index) => validateSchemaValue(item, spec.items, `${pointer}/${index}`, errors));
}

// Exact RFC3339 profile shared with the Python Bridge. Calendar validation
// precedes conversion, so impossible dates cannot roll into another month.
// A BigInt microsecond value preserves ordering that Date.parse truncates.
function parseTime(value) {
  if (typeof value !== 'string') return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match || match[0] !== value) return null;
  const year = Number(match[1]), month = Number(match[2]), day = Number(match[3]);
  const hour = Number(match[4]), minute = Number(match[5]), second = Number(match[6]);
  const offsetHour = Number(match[10] || 0), offsetMinute = Number(match[11] || 0);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > monthDays[month - 1] || hour > 23 || minute > 59 || second > 59 || offsetHour > 23 || offsetMinute > 59) return null;
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  const offsetMs = (offsetHour * 60 + offsetMinute) * 60000 * (match[9] === '-' ? -1 : 1);
  return BigInt(date.getTime() - offsetMs) * 1000n + BigInt((match[7] || '').slice(0, 6).padEnd(6, '0'));
}
function millisecondsToMicroseconds(value) {
  const whole = Math.trunc(value);
  return BigInt(whole) * 1000n + BigInt(Math.round((value - whole) * 1000));
}
function validateOwnerSummary(value) {
  if (typeof value !== 'string') return ['OWNER_SUMMARY_TYPE'];
  const errors = [];
  for (const heading of ['## Что происходит', '## Что уже сделано', '## Что будет дальше', '## Нужно ли что-то от владельца']) {
    if (!value.includes(heading)) errors.push(`OWNER_SUMMARY:${heading}`);
  }
  if (Array.from(value).length > 2400 || value.includes('```')) errors.push('OWNER_SUMMARY_FORMAT');
  return errors;
}
function validatePacketObject(packet, options = {}) {
  if (packet === null || typeof packet !== 'object' || Array.isArray(packet)) return {ok:false, errors:['PACKET_OBJECT']};
  const errors = [];
  for (const field of REQUIRED) if (!hasOwn(packet, field)) errors.push(`SCHEMA_REQUIRED:${field}`);
  for (const field of Object.keys(packet)) {
    if (!hasOwn(PROPERTIES, field)) errors.push(`SCHEMA_ADDITIONAL_PROPERTY:${field}`);
    else validateSchemaValue(packet[field], PROPERTIES[field], field, errors);
  }
  if (options === null || typeof options !== 'object' || Array.isArray(options)) return {ok:false, errors:[...errors,'OPTIONS_OBJECT'], packet};
  if (options.requireCapability === true) {
    if (!hasOwn(packet, 'capability_token')) errors.push('CAPABILITY_TOKEN');
  } else if (hasOwn(packet, 'capability_token')) errors.push('EXTERNAL_CAPABILITY_FORBIDDEN');
  // Cross-runtime integer portability is narrower than JSON Schema's integer:
  // reject identifiers already rounded by IEEE754 parsing in Node.
  if (typeof packet.goal_epoch === 'number' && !Number.isSafeInteger(packet.goal_epoch)) errors.push('GOAL_EPOCH_UNSAFE_INTEGER');
  if (packet.operation === 'continue_work_item' && (typeof packet.work_item_id !== 'string' || packet.work_item_id.length === 0 || !Number.isSafeInteger(packet.goal_epoch) || packet.goal_epoch < 1)) errors.push('CONTINUATION_IDENTITY');
  // Never normalize /goal here. Route adapters own any explicit migration;
  // validation must neither alter task intent nor mutate the input packet.
  if (typeof packet.technical_task_markdown !== 'string' || !packet.technical_task_markdown.trim()) errors.push('TECHNICAL_TASK');
  errors.push(...validateOwnerSummary(packet.owner_summary_ru));
  const created = parseTime(packet.created_at_utc), expires = parseTime(packet.expires_at_utc);
  if (created === null || expires === null || expires <= created) errors.push('PACKET_TIME_INVALID');
  const nowMs = hasOwn(options, 'nowMs') ? options.nowMs : Date.now();
  if (typeof nowMs !== 'number' || !Number.isFinite(nowMs)) errors.push('NOW_INVALID');
  else {
    const now = millisecondsToMicroseconds(nowMs);
    if (expires !== null && now > expires) errors.push('PACKET_EXPIRED');
    if (created !== null && created > now + 300000000n) errors.push('PACKET_FROM_FUTURE');
  }
  return {ok:errors.length === 0, errors, packet};
}
function readPacket(file) {
  try { return {packet:JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''))}; }
  catch (error) { return {result:{ok:false, errors:[error instanceof SyntaxError ? 'JSON_INVALID' : `PACKET_READ:${error.code || 'ERROR'}`]}}; }
}
function validatePacketPath(target, options = {}) {
  let stat;
  try { stat = fs.statSync(target); }
  catch (error) { return {ok:false, errors:[`PACKET_PATH:${error.code || 'ERROR'}`]}; }
  if (stat.isFile()) {
    if (path.extname(target).toLowerCase() !== '.json') return {ok:false, errors:['PACKET_EXTENSION']};
    const read = readPacket(target);
    return read.result || validatePacketObject(read.packet, options);
  }
  if (!stat.isDirectory()) return {ok:false, errors:['PACKET_PATH_TYPE']};
  const file = path.join(target, 'ACTION_PACKET.json');
  if (!fs.existsSync(file)) return {ok:false, errors:['MISSING:ACTION_PACKET.json']};
  const read = readPacket(file);
  if (read.result) return read.result;
  const result = validatePacketObject(read.packet, {...options, requireCapability:true});
  if (!result.ok) return result;
  const taskPath = path.join(target, 'AGENT_TASK.md');
  if (fs.existsSync(taskPath)) {
    let task;
    try { task = fs.readFileSync(taskPath, 'utf8'); }
    catch (error) { return {ok:false, errors:[`TASK_READ:${error.code || 'ERROR'}`]}; }
    if (read.packet.technical_task_markdown.trimEnd() !== task.trimEnd()) return {ok:false, errors:['TASK_MATERIALIZATION_MISMATCH']};
  }
  return result;
}
if (require.main === module) {
  const target = process.argv[2];
  if (!target) { console.error('Usage: action-packet.cjs <packet.json|materialized-directory>'); process.exit(2); }
  const result = validatePacketPath(target);
  // CLI diagnostics are exportable; local write-only capability stays in memory.
  console.log(JSON.stringify(result, (key, value) => key === 'capability_token' ? undefined : value, 2));
  process.exitCode = result.ok ? 0 : 1;
}
module.exports = {validatePacketObject, validatePacketPath};
