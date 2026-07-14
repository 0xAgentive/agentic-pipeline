#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const SUPPORTED_SCHEMA_KEYS = new Set([
  '$schema',
  '$id',
  'title',
  'description',
  'type',
  'required',
  'additionalProperties',
  'properties',
  'const',
  'enum',
  'pattern',
  'items',
  'minLength',
  'minItems'
]);

function fail(message) {
  console.error(message);
  process.exit(1);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function typeName(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (Number.isInteger(value)) return 'integer';
  if (typeof value === 'number') return 'number';
  return typeof value;
}

function assertSupportedSchema(schema, location = '$') {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw new Error(`${location}: schema node must be an object`);
  }

  for (const key of Object.keys(schema)) {
    if (!SUPPORTED_SCHEMA_KEYS.has(key)) {
      throw new Error(`${location}: unsupported schema keyword '${key}'`);
    }
  }

  if (schema.properties !== undefined) {
    if (!schema.properties || typeof schema.properties !== 'object' || Array.isArray(schema.properties)) {
      throw new Error(`${location}.properties must be an object`);
    }
    for (const [name, child] of Object.entries(schema.properties)) {
      assertSupportedSchema(child, `${location}.properties.${name}`);
    }
  }

  if (schema.items !== undefined) {
    assertSupportedSchema(schema.items, `${location}.items`);
  }
}

function checkType(value, expected) {
  const expectedTypes = Array.isArray(expected) ? expected : [expected];
  const actual = typeName(value);
  return expectedTypes.some((item) => {
    if (item === actual) return true;
    if (item === 'number' && actual === 'integer') return true;
    if (item === 'object' && actual === 'object' && value !== null && !Array.isArray(value)) return true;
    return false;
  });
}

function validateValue(schema, value, location = '$') {
  const errors = [];

  if (schema.type !== undefined && !checkType(value, schema.type)) {
    errors.push(`${location}: expected type ${JSON.stringify(schema.type)}, got ${typeName(value)}`);
    return errors;
  }

  if (schema.const !== undefined && !deepEqual(value, schema.const)) {
    errors.push(`${location}: expected const ${JSON.stringify(schema.const)}, got ${JSON.stringify(value)}`);
  }

  if (schema.enum !== undefined) {
    if (!Array.isArray(schema.enum)) {
      errors.push(`${location}: schema enum is not an array`);
    } else if (!schema.enum.some((candidate) => deepEqual(candidate, value))) {
      errors.push(`${location}: value ${JSON.stringify(value)} is not in enum`);
    }
  }

  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push(`${location}: string shorter than minLength ${schema.minLength}`);
    }
    if (schema.pattern !== undefined) {
      let regex;
      try {
        regex = new RegExp(schema.pattern);
      } catch (error) {
        errors.push(`${location}: invalid schema pattern: ${error.message}`);
        return errors;
      }
      if (!regex.test(value)) {
        errors.push(`${location}: value does not match pattern ${schema.pattern}`);
      }
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${location}: array shorter than minItems ${schema.minItems}`);
    }
    if (schema.items !== undefined) {
      value.forEach((item, index) => {
        errors.push(...validateValue(schema.items, item, `${location}[${index}]`));
      });
    }
  }

  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const properties = schema.properties || {};
    const required = schema.required || [];

    if (!Array.isArray(required)) {
      errors.push(`${location}: schema required is not an array`);
    } else {
      for (const key of required) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) {
          errors.push(`${location}: missing required property '${key}'`);
        }
      }
    }

    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!Object.prototype.hasOwnProperty.call(properties, key)) {
          errors.push(`${location}: additional property '${key}' is not allowed`);
        }
      }
    }

    for (const [key, childSchema] of Object.entries(properties)) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        errors.push(...validateValue(childSchema, value[key], `${location}.${key}`));
      }
    }
  }

  return errors;
}

function validateDocument(schema, document) {
  assertSupportedSchema(schema);
  return validateValue(schema, document);
}

function selfCheck() {
  const schema = {
    type: 'object',
    additionalProperties: false,
    required: ['mode', 'commands'],
    properties: {
      mode: { type: 'string', enum: ['normal', 'recovery'] },
      commands: {
        type: 'array',
        minItems: 1,
        items: { type: 'string', pattern: '^/' }
      }
    }
  };

  const valid = { mode: 'normal', commands: ['/auditphase'] };
  const checks = [
    { id: 'valid', value: valid, shouldPass: true },
    { id: 'missing_required', value: { commands: ['/auditphase'] }, shouldPass: false },
    { id: 'additional_property', value: { ...valid, extra: true }, shouldPass: false },
    { id: 'invalid_enum', value: { mode: 'invalid', commands: ['/auditphase'] }, shouldPass: false },
    { id: 'invalid_pattern', value: { mode: 'normal', commands: ['auditphase'] }, shouldPass: false }
  ];

  const failures = [];
  for (const item of checks) {
    const errors = validateDocument(schema, item.value);
    const passed = errors.length === 0;
    if (passed !== item.shouldPass) {
      failures.push(`${item.id}: expected pass=${item.shouldPass}, errors=${JSON.stringify(errors)}`);
    }
  }

  let unsupportedRejected = false;
  try {
    assertSupportedSchema({ type: 'string', oneOf: [] });
  } catch {
    unsupportedRejected = true;
  }
  if (!unsupportedRejected) failures.push('unsupported schema keyword was not rejected');

  if (failures.length) {
    for (const item of failures) console.error(`SELF-CHECK FAIL: ${item}`);
    process.exit(1);
  }

  console.log(`Independent schema contract self-check passed. Checks: ${checks.length + 1}`);
}

function parseArgs(argv) {
  const result = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value.startsWith('--')) {
      const key = value.slice(2);
      const next = argv[index + 1];
      if (next !== undefined && !next.startsWith('--')) {
        result[key] = next;
        index += 1;
      } else {
        result[key] = true;
      }
    } else {
      result._.push(value);
    }
  }
  return result;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args['self-check']) {
    selfCheck();
    return;
  }

  const command = args._[0];
  if (command !== 'validate') {
    fail('Usage: handshake-schema-contract.cjs --self-check | validate --schema <schema.json> --file <document.json>');
  }

  const schemaPath = path.resolve(args.schema || '');
  const filePath = path.resolve(args.file || '');
  if (!args.schema || !args.file) fail('--schema and --file are required');

  let schema;
  let document;
  try {
    schema = readJson(schemaPath);
    document = readJson(filePath);
  } catch (error) {
    fail(`JSON read failed: ${error.message}`);
  }

  let errors;
  try {
    errors = validateDocument(schema, document);
  } catch (error) {
    fail(`Schema contract rejected: ${error.message}`);
  }

  if (errors.length) {
    for (const error of errors) console.error(`FAIL: ${error}`);
    process.exit(1);
  }

  console.log(`Independent schema validation passed: ${filePath}`);
}

if (require.main === module) main();

module.exports = {
  assertSupportedSchema,
  validateDocument,
  validateValue
};
