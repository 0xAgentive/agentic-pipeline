#!/usr/bin/env node
'use strict';
const fs = require('fs');

const requiredHeadings = [
  '## Что происходит',
  '## Что уже сделано',
  '## Что будет дальше',
  '## Нужно ли что-то от владельца',
];
const forbidden = [
  /repair\s*budget/iu,
  /repair\s*batch/iu,
  /\bbatch\s*\d+\s*\/\s*\d+/iu,
  /\bexecution\s*lease\b/iu,
  /\bgoal\s*epoch\b/iu,
  /\bhandshake\b/iu,
  /\bmanifest\b/iu,
  /\bschema\b/iu,
  /\bsha-?256\b/iu,
  /\bbytes?\b/iu,
  /\b[A-Z][A-Z0-9]+-[A-Z][A-Z0-9]+-\d{2,}\b/u,
  /\/(?:nextphase|fixcritical|auditphase|fastpatch|shipcheck)\b/iu,
];
function validate(text) {
  const errors = [];
  const value = String(text || '').replace(/\r\n/g, '\n').trim();
  if (!value) errors.push('OWNER_SUMMARY_EMPTY');
  if (value.length > 2400) errors.push('OWNER_SUMMARY_TOO_LONG');
  for (const heading of requiredHeadings) if (!value.includes(heading)) errors.push(`HEADING_MISSING:${heading}`);
  const h2 = value.match(/^##\s+.+$/gm) || [];
  if (h2.length > 4) errors.push('TOO_MANY_SECTIONS');
  if (/```/.test(value)) errors.push('CODE_FENCE_FORBIDDEN');
  for (const pattern of forbidden) if (pattern.test(value)) errors.push(`TECHNICAL_TERM_FORBIDDEN:${pattern.source}`);
  return { ok: errors.length === 0, errors };
}
if (require.main === module) {
  const file = process.argv[2];
  const text = file ? fs.readFileSync(file, 'utf8') : fs.readFileSync(0, 'utf8');
  const result = validate(text);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exitCode = result.ok ? 0 : 1;
}
module.exports = { validate };
