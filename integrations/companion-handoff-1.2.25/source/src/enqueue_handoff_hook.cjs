#!/usr/bin/env node
'use strict';
const cp = require('child_process');
const fs = require('fs');

const pythonw = 'C:\\Users\\Администратор\\AppData\\Local\\Programs\\Python\\Python314\\pythonw.exe';
const script = 'C:\\Scripts\\AntigravityProjects\\companion-handoff\\src\\enqueue_ag_handoff.py';

const p = cp.spawn(pythonw, [script], {
  windowsHide: true,
  stdio: ['pipe', 'pipe', 'pipe']
});

process.stdin.pipe(p.stdin);
p.stdout.pipe(process.stdout);
p.stderr.pipe(process.stderr);

p.on('exit', (code) => {
  process.exit(code || 0);
});

p.on('error', (err) => {
  try {
    fs.appendFileSync('C:\\Scripts\\AntigravityProjects\\companion-handoff\\logs\\enqueue_error.log', `[${new Date().toISOString()}] HOOK_SPAWN_ERROR: ${err.message}\n`, 'utf8');
  } catch {}
  process.stdout.write(JSON.stringify({ decision: 'approve' }) + '\n');
  process.exit(0);
});
