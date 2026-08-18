#!/usr/bin/env node
'use strict';
const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const baseDir = process.env.COMPANION_HANDOFF_DIR || path.resolve(__dirname, '..');
const script = path.join(baseDir, 'src', 'enqueue_ag_handoff.py');

function findPython() {
  if (process.env.COMPANION_PYTHONW && fs.existsSync(process.env.COMPANION_PYTHONW)) {
    return process.env.COMPANION_PYTHONW;
  }
  if (process.env.LOCALAPPDATA) {
    const programsDir = path.join(process.env.LOCALAPPDATA, 'Programs', 'Python');
    if (fs.existsSync(programsDir)) {
      try {
        const entries = fs.readdirSync(programsDir).sort().reverse();
        for (const entry of entries) {
          const cand = path.join(programsDir, entry, 'pythonw.exe');
          if (fs.existsSync(cand)) return cand;
          const candPy = path.join(programsDir, entry, 'python.exe');
          if (fs.existsSync(candPy)) return candPy;
        }
      } catch {}
    }
  }
  return 'pythonw';
}

const pythonw = findPython();
const logsDir = path.join(baseDir, 'logs');

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
    fs.mkdirSync(logsDir, { recursive: true });
    fs.appendFileSync(path.join(logsDir, 'enqueue_error.log'), `[${new Date().toISOString()}] HOOK_SPAWN_ERROR: ${err.message}\n`, 'utf8');
  } catch {}
  process.stdout.write(JSON.stringify({ decision: 'approve' }) + '\n');
  process.exit(0);
});
