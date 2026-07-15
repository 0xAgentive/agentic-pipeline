#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (!item.startsWith('--')) fail(`Unexpected argument: ${item}`, 2);
    const key = item.slice(2);
    const next = argv[index + 1];
    if (next === undefined || next.startsWith('--')) {
      result[key] = true;
    } else {
      result[key] = next;
      index += 1;
    }
  }
  return result;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function normalizeArray(value) {
  return Array.isArray(value) ? value : [];
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args['repo-root'] || !args.output) {
    fail(
      'Usage: write-installation-manifest.cjs --repo-root <repo> --output <file> ' +
      '[--metadata-file <json>] [--mode <new|adopt>] [--state-profile <name>] ' +
      '[--source-repo <name>] [--source-commit <sha>]',
      2
    );
  }

  const repoRoot = path.resolve(args['repo-root']);
  const versionPath = path.join(repoRoot, 'VERSION.json');
  if (!fs.existsSync(versionPath)) fail(`VERSION.json not found: ${versionPath}`);

  const version = readJson(versionPath);
  const requiredVersionFields = [
    'package_version',
    'runtime_version',
    'playbook_version',
    'companion_version'
  ];
  for (const field of requiredVersionFields) {
    if (typeof version[field] !== 'string' || !version[field].trim()) {
      fail(`VERSION.json is missing ${field}`);
    }
  }

  let metadata = {};
  if (args['metadata-file']) {
    metadata = readJson(path.resolve(args['metadata-file']));
    if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
      fail('Metadata must be a JSON object');
    }
  }

  const mode = String(metadata.mode || args.mode || 'adopt').toLowerCase();
  if (!['new', 'adopt'].includes(mode)) fail(`Unsupported installation mode: ${mode}`);

  const stateProfile =
    metadata.state_profile ||
    args['state-profile'] ||
    (mode === 'new' ? 'new-project' : 'adopt-existing');

  const manifest = {
    schema_version: '1.1.0',
    installed_at_utc:
      metadata.installed_at_utc ||
      new Date().toISOString(),
    package_version: version.package_version,
    runtime_version: version.runtime_version,
    playbook_version: version.playbook_version,
    companion_version: version.companion_version,
    mode,
    state_profile: stateProfile,
    source_repo:
      metadata.source_repo ||
      args['source-repo'] ||
      'agentic-pipeline',
    source_commit:
      metadata.source_commit ||
      args['source-commit'] ||
      'unknown',
    conflict_policy:
      metadata.conflict_policy !== undefined
        ? metadata.conflict_policy
        : (args['conflict-policy'] || null),
    copied: normalizeArray(metadata.copied),
    skipped: normalizeArray(metadata.skipped),
    backed_up: normalizeArray(metadata.backed_up),
    backup_root:
      metadata.backup_root !== undefined
        ? metadata.backup_root
        : null,
    next_command:
      metadata.next_command ||
      args['next-command'] ||
      (mode === 'new' ? '/specdoc' : '/landing')
  };

  const outputPath = path.resolve(args.output);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

  console.log(`Installation manifest written: ${outputPath}`);
}

if (require.main === module) main();
