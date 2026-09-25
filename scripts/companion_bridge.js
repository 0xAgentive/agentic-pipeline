import { runtimePath } from './runtime_paths.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync as recoveryExecFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath as recoveryFileURLToPath } from 'node:url';
import { classifyBridgeDecision, decisionInstruction } from './typed-decision/bridge-adapter.mjs';
import {createTransportHost} from './transport-v2/host.mjs';
const transportV2 = createTransportHost({loadConfig, loadSeenPackets, saveSeenPackets, getRecoverySnapshot, connectToTab, detectProjectKey, getLatestHandoffZip, loadOwnerDirective, sendTelegramNotification, escapeHtml});

const CONFIG_PATH = runtimePath("ANTIGRAVITY_DATA_ROOT","companion_bridge_config.json");
const SEEN_PACKETS_PATH = runtimePath("ANTIGRAVITY_DATA_ROOT","companion_seen_packets.json");
const PUSHED_ZIPS_PATH = runtimePath("ANTIGRAVITY_DATA_ROOT","companion_pushed_zips.json");
const ACCEPTED_PACKETS_PATH = runtimePath("AGENTIC_STATE_ROOT","accepted_packets.ndjson");
const LOG_FILE_PATH = runtimePath("AGENTIC_STATE_ROOT","logs/companion_bridge.log");
const DOWNLOADS_DIR = runtimePath("AGENTIC_DOWNLOADS_DIR","");
const HANDOFF_BASE_DIR = runtimePath("AGENTIC_HANDOFF_ROOT","");
const STANDBY_STATE_PATH = runtimePath("AGENTIC_STATE_ROOT","STANDBY_STATE.json");
const OWNER_DIRECTIVE_PATH = runtimePath("AGENTIC_STATE_ROOT","OWNER_STRATEGIC_DIRECTIVE.json");
const API_HEARTBEAT_INTERVAL_MS = 60000;
const API_BACKOFF_DURATION_MS = 120000;
const RELOAD_GRACE_PERIOD_MS = 60000;
const lastApiCheckTime = {};
const apiBackoffUntil = {};
const lastReloadTime = {};
const activePushes = {};
const generationStartTime = {};
const candidatePacketGenTracker = {};
const PUSH_LOCK_DIR = runtimePath("AGENTIC_STATE_ROOT","locks");
if (!process.env.PYTHONPYCACHEPREFIX) {
  const pycacheDir = runtimePath("AGENTIC_STATE_ROOT", "cache/pycache");
  process.env.PYTHONPYCACHEPREFIX = pycacheDir;
  try { fs.mkdirSync(pycacheDir, { recursive: true }); } catch {}
}

export function acquirePushLock(projectKey) {
  try {
    if (!fs.existsSync(PUSH_LOCK_DIR)) fs.mkdirSync(PUSH_LOCK_DIR, { recursive: true });
    const lockFile = path.join(PUSH_LOCK_DIR, `push_${projectKey}.lock`);
    if (fs.existsSync(lockFile)) {
      try {
        const lockData = JSON.parse(fs.readFileSync(lockFile, 'utf-8'));
        const age = Date.now() - new Date(lockData.time).getTime();
        if (age < 90000 && lockData.pid !== process.pid) {
          return false;
        }
      } catch {
        const stat = fs.statSync(lockFile);
        if (Date.now() - stat.mtimeMs < 90000) return false;
      }
    }
    fs.writeFileSync(lockFile, JSON.stringify({ pid: process.pid, time: new Date().toISOString() }), 'utf-8');
    return true;
  } catch {
    return false;
  }
}

export function releasePushLock(projectKey) {
  try {
    const lockFile = path.join(PUSH_LOCK_DIR, `push_${projectKey}.lock`);
    if (fs.existsSync(lockFile)) {
      try {
        const lockData = JSON.parse(fs.readFileSync(lockFile, 'utf-8'));
        if (lockData.pid === process.pid) {
          fs.unlinkSync(lockFile);
        }
      } catch {
        fs.unlinkSync(lockFile);
      }
    }
  } catch {}
}

export function loadOwnerDirective() {
  try {
    if (fs.existsSync(OWNER_DIRECTIVE_PATH)) {
      return JSON.parse(fs.readFileSync(OWNER_DIRECTIVE_PATH, 'utf-8'));
    }
  } catch {}
  return null;
}

export function getRecoverySnapshot() {
  try {
    const helper = path.join(path.dirname(recoveryFileURLToPath(import.meta.url)), 'pipeline_runtime_state.py');
    const text = recoveryExecFileSync(runtimePath('AGENTIC_PYTHONW'), [helper], {
      encoding: 'utf8', timeout: 5000, windowsHide: true, maxBuffer: 1024 * 1024
    });
    const state = JSON.parse(text);
    if (state.schema_version !== 1 || typeof state.is_standby !== 'boolean') throw new Error('invalid state');
    return state;
  } catch {
    return {is_standby: true, mode: 'UNKNOWN', reason: 'STATE_UNAVAILABLE', projects: {}};
  }
}

export function isPipelineInStandby() {
  return getRecoverySnapshot().is_standby;
}

export function isProjectInStandby(projectKey) {
  const state = getRecoverySnapshot();
  return state.is_standby || state.projects?.[projectKey]?.is_paused === true;
}

let cachedConfig = null;
let cachedConfigMtime = 0;

export function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      const stat = fs.statSync(CONFIG_PATH);
      if (cachedConfig && stat.mtimeMs === cachedConfigMtime) {
        return cachedConfig;
      }
      cachedConfig = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf-8'));
      cachedConfigMtime = stat.mtimeMs;
      return cachedConfig;
    }
  } catch {}
  if (cachedConfig) return cachedConfig;
  return {
    telegram: {
      botToken: '',
      chatId: '1633903264',
      enabled: false
    },
    browser: {
      cdpUrl: 'http://127.0.0.1:9222',
      pollIntervalMs: 5000,
      companions: {
        h10: {
          name: 'H10 Athlete Cardio Lab',
          urlPattern: '6a972629-1bc8-83ea-966d-1e48404d8c16'
        },
        vitalis: {
          name: 'Vitalis',
          urlPattern: '6a9815e0-b6f4-83e9-a8d1-7aa83b0ace55'
        }
      }
    }
  };
}

export function logMessage(msg) {
  const timestamp = new Date().toISOString();
  const line = `[${timestamp}] ${msg}`;
  console.log(line);
  try {
    const dir = path.dirname(LOG_FILE_PATH);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    if (fs.existsSync(LOG_FILE_PATH)) {
      try {
        const stats = fs.statSync(LOG_FILE_PATH);
        if (stats.size > 5 * 1024 * 1024) {
          const oldPath = LOG_FILE_PATH + '.old';
          try { if (fs.existsSync(oldPath)) fs.unlinkSync(oldPath); } catch {}
          try { fs.renameSync(LOG_FILE_PATH, oldPath); } catch {}
        }
      } catch {}
    }
    fs.appendFileSync(LOG_FILE_PATH, line + '\n', 'utf-8');
  } catch {}
}

export function loadSeenPackets() {
  if (fs.existsSync(SEEN_PACKETS_PATH)) {
    try {
      return JSON.parse(fs.readFileSync(SEEN_PACKETS_PATH, 'utf-8'));
    } catch {}
  }
  return {};
}

export function saveSeenPackets(seen) {
  try {
    const dir = path.dirname(SEEN_PACKETS_PATH);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(SEEN_PACKETS_PATH, JSON.stringify(seen, null, 2), 'utf-8');
  } catch (err) {
    logMessage(`[Warn] Не удалось сохранить seen_packets: ${err.message}`);
  }
}

export function loadPushedZips() {
  if (fs.existsSync(PUSHED_ZIPS_PATH)) {
    try {
      return JSON.parse(fs.readFileSync(PUSHED_ZIPS_PATH, 'utf-8'));
    } catch {}
  }
  return {};
}

export function savePushedZips(pushed) {
  try {
    const dir = path.dirname(PUSHED_ZIPS_PATH);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(PUSHED_ZIPS_PATH, JSON.stringify(pushed, null, 2), 'utf-8');
  } catch (err) {
    logMessage(`[Warn] Не удалось сохранить pushed_zips: ${err.message}`);
  }
}

export function isZipAlreadyPushed(pushedZips, zipPath) {
  if (!zipPath || !pushedZips) return false;
  if (pushedZips[zipPath]) return true;
  const baseName = path.basename(zipPath);
  if (pushedZips[baseName]) return true;
  for (const [p, val] of Object.entries(pushedZips)) {
    if (val && !String(val).startsWith('FAILED_') && path.basename(p) === baseName) {
      return true;
    }
  }
  return false;
}

export function detectProjectKey(input) {
  if (!input) return null;
  const lower = String(input).toLowerCase();
  const config = loadConfig();
  const companions = config.browser?.companions || {};

  for (const key of Object.keys(companions)) {
    if (lower === key.toLowerCase()) return key;
  }

  for (const [key, comp] of Object.entries(companions)) {
    if (lower.includes(key.toLowerCase())) return key;
    if (comp.name && lower.includes(comp.name.toLowerCase())) return key;
    if (comp.projectFolder && lower.includes(comp.projectFolder.toLowerCase())) return key;
    if (comp.antigravityConversationId && lower.includes(comp.antigravityConversationId.toLowerCase())) return key;
    if (comp.urlPattern && lower.includes(comp.urlPattern.toLowerCase())) return key;
  }

  if (lower.includes('h10') || lower.includes('athlete_cardio')) return 'h10';
  if (lower.includes('vitalis') || lower.includes('huawei')) return 'vitalis';

  return null;
}

const lastExportedZipPath = {};

export function getLatestHandoffZip(projectKey) {
  const config = loadConfig();
  const comp = config.browser?.companions?.[projectKey];
  const candidateNames = new Set([
    comp?.projectFolder,
    comp?.name,
    projectKey === 'h10' ? 'H10 Athlete Cardio Lab' : null,
    projectKey === 'vitalis' ? 'Huawei Health export' : null,
    projectKey === 'vitalis' ? 'frontend' : null,
  ].filter(Boolean));

  for (const name of Array.from(candidateNames)) {
    candidateNames.add(name.toLowerCase().replace(/\s+/g, '-'));
    candidateNames.add(name.replace(/\s+/g, '_'));
  }

  if (comp?.antigravityConversationId && fs.existsSync(HANDOFF_BASE_DIR)) {
    try {
      const topDirs = fs.readdirSync(HANDOFF_BASE_DIR, { withFileTypes: true })
        .filter(d => d.isDirectory())
        .map(d => d.name);
      for (const d of topDirs) {
        const specDir = path.join(HANDOFF_BASE_DIR, d, comp.antigravityConversationId, 'latest');
        if (fs.existsSync(specDir)) {
          candidateNames.add(d);
        }
      }
    } catch {}
  }

  let newestZip = null;
  let newestMtime = 0;
  if (lastExportedZipPath[projectKey] && fs.existsSync(lastExportedZipPath[projectKey])) {
    try {
      newestZip = lastExportedZipPath[projectKey];
      newestMtime = fs.statSync(newestZip).mtimeMs;
    } catch {}
  }

  for (const projDirName of candidateNames) {
    const fullProjDir = path.join(HANDOFF_BASE_DIR, projDirName);
    if (!fs.existsSync(fullProjDir)) continue;

    let convDirs = [];
    try {
      if (comp?.antigravityConversationId) {
        const specificDir = path.join(fullProjDir, comp.antigravityConversationId, 'latest');
        if (fs.existsSync(specificDir)) {
          convDirs.push(specificDir);
        }
      }
      const allDirs = fs.readdirSync(fullProjDir, { withFileTypes: true })
        .filter(d => d.isDirectory())
        .map(d => path.join(fullProjDir, d.name, 'latest'));
      for (const d of allDirs) {
        if (!convDirs.includes(d)) convDirs.push(d);
      }
    } catch {
      continue;
    }

    for (const latestDir of convDirs) {
      if (!fs.existsSync(latestDir)) continue;
      try {
        const files = fs.readdirSync(latestDir);
        for (const f of files) {
          if (f.endsWith('.zip') && !f.startsWith('.') && f !== 'LATEST_CONTEXT.zip') {
            const fullPath = path.join(latestDir, f);
            const stat = fs.statSync(fullPath);
            // Never prefer a hollow skeleton archive (< 25 KB) over a full context archive
            if (stat.size < 25000 && newestZip && fs.statSync(newestZip).size >= 25000) continue;
            if (stat.mtimeMs > newestMtime || (newestZip && fs.statSync(newestZip).size < 25000 && stat.size >= 25000)) {
              newestMtime = stat.mtimeMs;
              newestZip = fullPath;
            }
          }
        }
      } catch {}
    }
  }

  return newestZip;
}

const activeExports = new Set();
const lastExportAttempt = {};
const exportFailureCount = {};

export function isProjectExecuting(projectKey, comp) {
  if (!comp?.projectPath || !fs.existsSync(comp.projectPath)) return false;
  const nextActionPath = path.join(comp.projectPath, '.agy', 'NEXT_ACTION.json');
  if (!fs.existsSync(nextActionPath)) return false;
  try {
    const nextAction = JSON.parse(fs.readFileSync(nextActionPath, 'utf8'));
    if (nextAction.route !== null || nextAction.auto_continue === true) {
      const isFinishingRoute = nextAction.route === null || ['/auditphase', '/shipcheck', '/close'].includes(nextAction.route);
      const closurePath = path.join(comp.projectPath, '.agy', 'CLOSURE_STATE.json');
      if (fs.existsSync(closurePath)) {
        try {
          const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
          if (closure.work_item_id === nextAction.work_item_id && (closure.implementation_status === 'completed' || closure.next_owner_goal_allowed === true || closure.closure_reason === 'true_owner_decision_required' || nextAction.owner_decision_required === true)) {
            return false;
          }
        } catch {}
      }
      const runPath = path.join(comp.projectPath, '.agy', 'RUN_RESULT.json');
      if (fs.existsSync(runPath)) {
        try {
          const run = JSON.parse(fs.readFileSync(runPath, 'utf8'));
          if (run.work_item_id === nextAction.work_item_id && (run.implementation_status === 'completed' || nextAction.owner_decision_required === true)) {
            return false;
          }
        } catch {}
      }
      if (isFinishingRoute && nextAction.auto_continue !== true) {
        return false;
      }
      return true;
    }
  } catch {}
  return false;
}

export function checkProjectNeedsHandoffExport(projectKey, comp, result, currentZip) {
  if (!comp?.projectPath || !fs.existsSync(comp.projectPath)) return false;
  const nextActionPath = path.join(comp.projectPath, '.agy', 'NEXT_ACTION.json');
  if (!fs.existsSync(nextActionPath)) return false;

  try {
    const nextAction = JSON.parse(fs.readFileSync(nextActionPath, 'utf8'));
    const closurePath = path.join(comp.projectPath, '.agy', 'CLOSURE_STATE.json');
    const workPath = path.join(comp.projectPath, '.agy', 'WORK_ITEM.json');
    const runPath = path.join(comp.projectPath, '.agy', 'RUN_RESULT.json');
    let isCompleted = false;
    if (fs.existsSync(closurePath)) {
      try {
        const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
        let currentWiId = null;
        if (fs.existsSync(workPath)) {
          try { currentWiId = JSON.parse(fs.readFileSync(workPath, 'utf8')).work_item_id; } catch {}
        }
        const actResPath = path.join(comp.projectPath, '.agy', 'ACTION_PACKET_ACTIVATION_RESULT.json');
        let isStaleClosure = false;
        if (fs.existsSync(actResPath)) {
          try {
            const actRes = JSON.parse(fs.readFileSync(actResPath, 'utf8'));
            if (closure.generated_at_utc && actRes.activated_at_utc) {
              if (new Date(closure.generated_at_utc).getTime() < new Date(actRes.activated_at_utc).getTime()) {
                isStaleClosure = true;
              }
            }
          } catch {}
        }
        if (!isStaleClosure && (closure.implementation_status === 'completed' || closure.next_owner_goal_allowed === true || closure.closure_reason === 'true_owner_decision_required' || nextAction.owner_decision_required === true) &&
            (!currentWiId || closure.work_item_id === currentWiId)) {
          isCompleted = true;
          if (nextAction.route !== null || nextAction.auto_continue === true) {
            logMessage(`[Auto-Close] Work item ${closure.work_item_id || currentWiId} completed in CLOSURE_STATE. Auto-closing NEXT_ACTION route...`);
            nextAction.route = null;
            nextAction.auto_continue = false;
            nextAction.updated_at_utc = new Date().toISOString();
            fs.writeFileSync(nextActionPath, JSON.stringify(nextAction, null, 2), 'utf8');
            if (fs.existsSync(workPath)) {
              try {
                const wi = JSON.parse(fs.readFileSync(workPath, 'utf8'));
                if (wi.status !== 'completed') {
                  wi.status = 'completed';
                  wi.updated_at_utc = new Date().toISOString();
                  fs.writeFileSync(workPath, JSON.stringify(wi, null, 2), 'utf8');
                }
              } catch {}
            }
          }
        }
      } catch {}
    }
    if (!isCompleted && fs.existsSync(runPath)) {
      try {
        const run = JSON.parse(fs.readFileSync(runPath, 'utf8'));
        let currentWiId = null;
        if (fs.existsSync(workPath)) {
          try { currentWiId = JSON.parse(fs.readFileSync(workPath, 'utf8')).work_item_id; } catch {}
        }
        if (run.implementation_status === 'completed' && (!currentWiId || run.work_item_id === currentWiId)) {
          isCompleted = true;
        }
      } catch {}
    }
    if (!isCompleted && fs.existsSync(workPath)) {
      try {
        const wi = JSON.parse(fs.readFileSync(workPath, 'utf8'));
        if (wi.status === 'completed' && nextAction.route === null && nextAction.auto_continue !== true) {
          isCompleted = true;
        }
      } catch {}
    }
    if (!isCompleted) {
      if (nextAction.route !== null || nextAction.auto_continue === true) return false;
      return false;
    }

    if (!currentZip || !fs.existsSync(currentZip)) return true;

    const zipMtime = fs.statSync(currentZip).mtimeMs;
    const nextActionMtime = fs.statSync(nextActionPath).mtimeMs;
    const closureMtime = fs.existsSync(closurePath) ? fs.statSync(closurePath).mtimeMs : 0;
    const workMtime = fs.existsSync(workPath) ? fs.statSync(workPath).mtimeMs : 0;
    const runMtime = fs.existsSync(runPath) ? fs.statSync(runPath).mtimeMs : 0;
    const maxStateMtime = Math.max(nextActionMtime, closureMtime, workMtime, runMtime);
    if (maxStateMtime > zipMtime + 5000) {
      return true;
    }
  } catch {
    return false;
  }
  return false;
}

export async function triggerHandoffExport(projectKey, comp) {
  if (activeExports.has(projectKey)) return false;
  const now = Date.now();
  if (lastExportAttempt[projectKey] && now - lastExportAttempt[projectKey] < 45000) {
    return false;
  }
  const convId = comp?.antigravityConversationId;
  if (!convId) return false;

  const handoffRoot = runtimePath('AGENTIC_HANDOFF_ROOT');
  let exporterScript = path.join(handoffRoot, '..', 'src', 'export_ag_handoff.py');
  if (!fs.existsSync(exporterScript)) {
    exporterScript = 'C:\\Scripts\\AntigravityProjects\\companion-handoff\\src\\export_ag_handoff.py';
  }
  let pythonExe = runtimePath('AGENTIC_PYTHON');
  if (!pythonExe || !fs.existsSync(pythonExe)) {
    pythonExe = (process.env.LOCALAPPDATA || 'C:\\Users\\Администратор\\AppData\\Local') + '\\Programs\\Python\\Python314\\python.exe';
  }

  activeExports.add(projectKey);
  lastExportAttempt[projectKey] = now;
  logMessage(`[Auto-Export] Project ${projectKey} (${comp.name}) completed work item. Exporting fresh context pack...`);

  return new Promise((resolve) => {
    const proc = spawn(pythonExe, [exporterScript, convId], {
      cwd: path.dirname(exporterScript),
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let killed = false;
    const timer = setTimeout(() => {
      killed = true;
      try { proc.kill('SIGKILL'); } catch {}
      activeExports.delete(projectKey);
      logMessage(`[Auto-Export Error] Exporter timed out after 90s for ${comp.name}`);
      resolve(false);
    }, 90000);

    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });

    proc.on('close', (code) => {
      clearTimeout(timer);
      if (killed) return;
      activeExports.delete(projectKey);
      let parsed = null;
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {}
      if (code === 0 && parsed && parsed.status === 'SUCCESS') {
        exportFailureCount[projectKey] = 0;
        logMessage(`[Auto-Export] Successfully generated fresh handoff archive for ${comp.name}: ${parsed.archive_path || ''}`);
        if (parsed.archive_path && fs.existsSync(parsed.archive_path)) {
          lastExportedZipPath[projectKey] = parsed.archive_path;
        }
        checkAndAutoRotateProject(projectKey, comp);
        resolve(true);
      } else {
        const detail = parsed?.error || parsed?.details || stderr || stdout;
        exportFailureCount[projectKey] = (exportFailureCount[projectKey] || 0) + 1;
        logMessage(`[Auto-Export Error] Exporter failed for ${comp.name} (code ${code}): ${detail} (попытка ${exportFailureCount[projectKey]})`);
        if (exportFailureCount[projectKey] >= 2) {
          sendTelegramNotification(
            `⚠️ <b>СБОЙ АВТО-ЭКСПОРТА КОНТЕКСТА (${comp.name})</b>\n\n` +
            `• <b>Код:</b> <code>${code}</code>\n` +
            `• <b>Детали:</b> <code>${escapeHtml(typeof detail === 'object' ? JSON.stringify(detail) : String(detail)).slice(0, 300)}</code>\n\n` +
            `<i>Выполняется автоматическая очистка и повторная попытка экспорта.</i>`,
            300000
          );
        }
        resolve(false);
      }
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      if (killed) return;
      activeExports.delete(projectKey);
      logMessage(`[Auto-Export Error] Failed to launch exporter: ${err.message}`);
      resolve(false);
    });
  });
}

const lastRotationCheck = {};

export function checkAndAutoRotateProject(projectKey, comp) {
  if (!comp?.antigravityConversationId) return false;
  const now = Date.now();
  if (lastRotationCheck[projectKey] && (now - lastRotationCheck[projectKey] < 30000)) {
    return false;
  }
  lastRotationCheck[projectKey] = now;

  const convId = comp.antigravityConversationId;
  const transcriptPath = path.join(
    process.env.USERPROFILE || 'C:\\Users\\Администратор',
    '.gemini', 'antigravity', 'brain', convId, '.system_generated', 'logs', 'transcript.jsonl'
  );
  if (!fs.existsSync(transcriptPath)) return false;

  let sizeMb = 0;
  try {
    sizeMb = fs.statSync(transcriptPath).size / (1024 * 1024);
  } catch {
    return false;
  }

  // Threshold: >= 10.0 MB
  if (sizeMb >= 10.0) {
    if (isProjectExecuting(projectKey, comp)) {
      logMessage(`[Auto-Rotate] Project ${comp.name} conversation is overloaded (${sizeMb.toFixed(2)} MB), but actively executing. Deferring to completion.`);
      return false;
    }

    logMessage(`[Auto-Rotate] Conversation ${convId} for ${comp.name} is overloaded (${sizeMb.toFixed(2)} MB). Triggering auto-rotation...`);
    const rotateScript = path.join(path.dirname(recoveryFileURLToPath(import.meta.url)), 'rotate_active_dialog.py');
    let pythonExe = runtimePath('AGENTIC_PYTHON');
    if (!pythonExe || !fs.existsSync(pythonExe)) {
      pythonExe = (process.env.LOCALAPPDATA || 'C:\\Users\\Администратор\\AppData\\Local') + '\\Programs\\Python\\Python314\\python.exe';
    }

    try {
      const res = recoveryExecFileSync(pythonExe, [rotateScript, projectKey, '--auto'], {
        encoding: 'utf8',
        timeout: 45000,
        windowsHide: true
      });
      logMessage(`[Auto-Rotate] Rotation output for ${comp.name}: ${res.trim()}`);
      cachedConfigMtime = 0;
      cachedConfig = null;
      return true;
    } catch (err) {
      logMessage(`[Auto-Rotate Error] Failed to rotate ${comp.name}: ${err.message}`);
    }
  }
  return false;
}

export function isPacketAlreadyAccepted(packetId, fileName) {
  if (fileName) {
    // Only timestamped filenames like AGENTIC_ACTION_PACKET_H10_20260905_123456.json are globally unique by filename!
    // Generic names like AGENTIC_ACTION_PACKET_H10.json or AGENTIC_ACTION_PACKET_VITALIS.json are NOT unique by filename alone.
    const isTimestamped = /\d{8}[-_]\d{6}/.test(fileName);
    if (isTimestamped) {
      const processedDir = runtimePath("AGENTIC_STATE_ROOT","processed");
      if (fs.existsSync(path.join(processedDir, fileName))) return true;
      const failedDir = runtimePath("AGENTIC_STATE_ROOT","failed");
      if (fs.existsSync(path.join(failedDir, fileName))) return true;
      const inboxDir = DOWNLOADS_DIR;
      if (fs.existsSync(path.join(inboxDir, fileName))) return true;
    }
  }
  if (!fs.existsSync(ACCEPTED_PACKETS_PATH)) return false;
  try {
    const lines = fs.readFileSync(ACCEPTED_PACKETS_PATH, 'utf-8').split('\n');
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const item = JSON.parse(line);
        if (packetId && item.packet_id === packetId) return true;
      } catch {}
    }
  } catch {}
  return false;
}

export function isPacketSeenOrAccepted(projectKey, fileName) {
  if (!fileName) return false;
  const seen = loadSeenPackets();
  const fileRecord = seen[projectKey]?.seenFiles?.[fileName];
  if (fileRecord) {
    if (typeof fileRecord === 'string' && fileRecord.startsWith('FAILED_PULL_')) {
      return false; // A failed pull attempt must NEVER prevent future retries!
    }
    // Recorded in seenFiles: IT IS SEEN!
    return true;
  }
  if (seen[projectKey]?.fileName === fileName) {
    return true;
  }
  return isPacketAlreadyAccepted(null, fileName);
}

function escapeHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function loadProjectNextAction(projectPath) {
  if (!projectPath) return null;
  try {
    const naPath = path.join(projectPath, '.agy', 'NEXT_ACTION.json');
    if (fs.existsSync(naPath)) {
      return JSON.parse(fs.readFileSync(naPath, 'utf-8'));
    }
  } catch {}
  return null;
}

const sentNotificationCache = new Map();
let telegramBackoffUntil = 0;

export async function sendTelegramNotification(htmlText, minIntervalMs = 300000, replyMarkup = null) {
  const config = loadConfig();
  const token = config.telegram?.botToken;
  const chatId = config.telegram?.chatId;
  if (!config.telegram?.enabled || !token || !chatId) {
    logMessage('[Telegram] Уведомления отключены в конфигурации.');
    return;
  }

  const now = Date.now();
  if (now < telegramBackoffUntil && !replyMarkup && minIntervalMs > 0) {
    logMessage(`[Telegram Throttled] Rate limit backoff active (ещё ${Math.round((telegramBackoffUntil - now) / 1000)}с).`);
    return;
  }

  // Deduplication guard: ignore identical notification sent within minIntervalMs (default 5 min)
  const cleanKey = htmlText.replace(/\s+/g, ' ').trim();
  const lastSent = sentNotificationCache.get(cleanKey) || 0;
  if (now - lastSent < minIntervalMs) {
    logMessage(`[Telegram Throttled] Пропуск дублирующего уведомления (отправлено ${Math.round((now - lastSent) / 1000)}с назад).`);
    return;
  }
  sentNotificationCache.set(cleanKey, now);

  // Clean old cache entries
  if (sentNotificationCache.size > 200) {
    for (const [k, t] of sentNotificationCache.entries()) {
      if (now - t > 3600000) sentNotificationCache.delete(k);
    }
  }

  try {
    const payload = {
      chat_id: chatId,
      text: htmlText,
      parse_mode: 'HTML'
    };
    if (replyMarkup) {
      payload.reply_markup = replyMarkup;
    }
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!data.ok) {
      logMessage(`[Telegram] Ошибка sendMessage: ${data.description}`);
      if (data.parameters?.retry_after) {
        telegramBackoffUntil = Date.now() + (data.parameters.retry_after * 1000) + 1000;
        logMessage(`[Telegram] Установлен backoff на ${data.parameters.retry_after}с.`);
      }
    }
  } catch (err) {
    logMessage(`[Telegram] Сбой отправки сообщения: ${err.message}`);
  }
}

export function triggerSupervisorDiagnostic(projectKey, comp, state, stalledMinutes, details = '') {
  try {
    const triggerScript = path.join(runtimePath('AGENTIC_PIPELINE_ROOT'), 'scripts', 'bridge', 'trigger_supervisor_diagnostic.py');
    if (!fs.existsSync(triggerScript)) {
      logMessage(`[Watchdog Error] Diagnostic script not found: ${triggerScript}`);
      return false;
    }
    const pythonExe = runtimePath('AGENTIC_PYTHON');
    logMessage(`[Watchdog] 🚨 Запуск диагностики супервизора для ${comp.name} (${projectKey})...`);
    const child = spawn(pythonExe, [
      triggerScript,
      '--project-key', projectKey,
      '--reason', 'STALLED_CYCLE_TIMEOUT',
      '--details', `Состояние транспорта: ${state}. ${details}`,
      '--stalled-minutes', String(stalledMinutes)
    ], {
      detached: true,
      stdio: 'ignore',
      windowsHide: true
    });
    child.unref();
    return true;
  } catch (err) {
    logMessage(`[Watchdog Error] Ошибка вызова диагностики: ${err.message}`);
    return false;
  }
}

export async function autoNudgeSilentFreeze(conn, comp) {
  if (!conn || !conn.send) return false;
  logMessage(`[Watchdog Auto-Nudge] ⚡ Обнаружен тихий сбой OpenAI. Попытка автоматического перезапуска генерации для ${comp.name}...`);
  try {
    const clickEditExpr = `(() => {
      const editBtns = Array.from(document.querySelectorAll('button[aria-label="Редактировать сообщение"], button[aria-label="Edit message"]'));
      const lastEditBtn = editBtns[editBtns.length - 1];
      if (lastEditBtn) {
        lastEditBtn.click();
        return { clicked: true };
      }
      return { clicked: false, count: editBtns.length };
    })()`;
    const editRes = await conn.send('Runtime.evaluate', { expression: clickEditExpr, returnByValue: true }, 5000);
    if (editRes?.result?.value?.clicked) {
      await new Promise(r => setTimeout(r, 1500));
      const clickSendExpr = `(() => {
        const btns = Array.from(document.querySelectorAll('button'));
        const sendBtn = btns.find(b => {
          const l = (b.getAttribute('aria-label') || '').toLowerCase();
          const t = b.innerText.trim().toLowerCase();
          return l.includes('отправить') || l.includes('send') || t === 'отправить' || t === 'send' || b.classList.contains('bg-composer-primary') || b.getAttribute('type') === 'submit';
        });
        if (sendBtn && !sendBtn.disabled) {
          const f = sendBtn.closest('form');
          if (typeof f?.requestSubmit === 'function') {
            try { f.requestSubmit(sendBtn); } catch {}
          }
          try {
            sendBtn.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, view: window }));
            sendBtn.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
            sendBtn.click();
          } catch {}
          return { clicked: true };
        }
        return { clicked: false };
      })()`;
      const sendRes = await conn.send('Runtime.evaluate', { expression: clickSendExpr, returnByValue: true }, 5000);
      if (sendRes?.result?.value?.clicked) {
        logMessage(`[Watchdog Auto-Nudge] ✅ Успешно нажат Edit -> Send для ${comp.name}`);
        return true;
      }
    }
    logMessage(`[Watchdog Auto-Nudge] Кнопки редактирования не найдены. conn.reload() пропущен во избежание Cloudflare 429 ("босс").`);
    return false;
  } catch (err) {
    logMessage(`[Watchdog Auto-Nudge Error] Ошибка auto-nudge: ${err.message}`);
    return false;
  }
}

const activeTabConnections = new Map();

export async function connectToTab(tabUrlPattern, options = {}) {
  const cached = activeTabConnections.get(tabUrlPattern);
  if (cached && cached.ws?.readyState === 1 /* WebSocket.OPEN */ && !options.forceNew) {
    if (typeof cached.conn?.keepActive === 'function') {
      cached.conn.keepActive().catch(() => {});
    }
    return cached.conn;
  }

  const config = loadConfig();
  const cdpUrl = config.browser?.cdpUrl || 'http://127.0.0.1:9222';
  const listResp = await fetch(`${cdpUrl}/json/list`);
  const tabs = await listResp.json();
  const matchingTabs = tabs.filter(t => {
    try { const u = new URL(t.url); return u.protocol === 'https:' && ['chatgpt.com','chat.openai.com'].includes(u.hostname) && u.pathname.split('/').filter(Boolean).at(-1) === tabUrlPattern; } catch { return false; }
  });
  if (matchingTabs.length !== 1) throw new Error('EXACT_CONVERSATION_TAB_REQUIRED');
  const tab = matchingTabs[0];
  if (!tab) {
    throw new Error(`Вкладка с URL-паттерном "${tabUrlPattern}" не найдена среди открытых страниц браузера.`);
  }

  logMessage(`[CDP] Новое подключение к вкладке: "${tab.title}" (${tab.id})...`);
  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error(`Таймаут подключения WebSocket к ${tab.webSocketDebuggerUrl}`));
    }, 5000);
    ws.onopen = () => {
      clearTimeout(timer);
      resolve();
    };
    ws.onerror = (err) => {
      clearTimeout(timer);
      reject(new Error(`Ошибка WebSocket соединения: ${err.message || String(err)}`));
    };
  });
  ws.onclose = () => {
    activeTabConnections.delete(tabUrlPattern);
  };
  logMessage(`[CDP] WebSocket подключен и сохранён в пуле.`);

  let msgId = 1;
  function send(method, params = {}, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      if (ws.readyState !== 1) {
        activeTabConnections.delete(tabUrlPattern);
        return reject(new Error('CDP_WEBSOCKET_CLOSED'));
      }
      const id = msgId++;
      const timeout = setTimeout(() => {
        ws.removeEventListener('message', handler);
        reject(new Error(`CDP таймаут для ${method}`));
      }, timeoutMs);

      const handler = (evt) => {
        const data = JSON.parse(evt.data);
        if (data.id === id) {
          clearTimeout(timeout);
          ws.removeEventListener('message', handler);
          if (data.error) reject(new Error(data.error.message || JSON.stringify(data.error)));
          else resolve(data.result);
        }
      };
      ws.addEventListener('message', handler);
      ws.send(JSON.stringify({ id, method, params }));
    });
  }

  // Prevent background throttling & sleeping tab discard by Chromium (APPLIES STRICTLY AND EXCLUSIVELY TO THIS COMPANION TAB)
  async function keepCompanionTabActive() {
    try {
      await send('Page.enable', {}, 2000);
      await send('Page.setWebLifecycleState', { state: 'active' }, 2000);
    } catch {}
    if (config.browser?.watchdog?.focusEmulation !== false) {
      try {
        await send('Emulation.setFocusEmulationEnabled', { enabled: true }, 2000);
      } catch {}
    }
  }

  await keepCompanionTabActive();

  async function reload(options = {}) {
    // HARD INVARIANT: Page.reload is strictly prohibited to avoid Cloudflare/OpenAI 429 Too Many Requests and project ejects.
    if (options.forceHard) {
      logMessage(`[CDP] Hard reload requested but suppressed by policy (No-Reload Invariant). Executing soft sync for "${tab.title}" (${tab.id})...`);
    }
    logMessage(`[CDP] Мягкая синхронизация (soft reload) страницы "${tab.title}" (${tab.id})...`);
    try {
      const res = await send('Runtime.evaluate', {
        expression: `(() => {
          const convId = location.pathname.match(/(?:^|\/)c\/([A-Za-z0-9-]+)(?:\/|$)/)?.[1];
          if (convId) {
            const link = document.querySelector(\`nav a[href*="\${convId}"], a[href*="/c/\${convId}"]\`);
            if (link) { link.click(); return { method: 'sidebar_click', success: true }; }
          }
          window.history.pushState(null, '', window.location.href);
          window.dispatchEvent(new PopStateEvent('popstate'));
          return { method: 'popstate', success: true };
        })()`,
        returnByValue: true
      }, 5000);
      logMessage(`[CDP] Мягкая синхронизация завершена: ${JSON.stringify(res.result?.value)}`);
    } catch (err) {
      logMessage(`[CDP Warn] Ошибка soft reload: ${err.message}`);
    }
  }

  const conn = {
    tab,
    ws,
    send,
    reload,
    keepActive: keepCompanionTabActive,
    close: () => {
      activeTabConnections.delete(tabUrlPattern);
      try { ws.close(); } catch {}
    }
  };

  ws.onclose = () => {
    activeTabConnections.delete(tabUrlPattern);
  };
  ws.onerror = () => {
    activeTabConnections.delete(tabUrlPattern);
  };

  activeTabConnections.set(tabUrlPattern, { conn, ws, tabId: tab.id });
  return conn;
}

export function classifyResponseWithoutPacket(text) {
  if (!text || typeof text !== 'string') {
    return { scenario: 'UNKNOWN', reason: 'Empty text' };
  }

  function extractSection(headingNames) {
    for (const heading of headingNames) {
      // Matches:
      // ### Heading
      // **Heading**
      // Heading:
      // Heading\n
      const regex = new RegExp('(?:^|\\n)(?:#{1,3}\\s*|\\*\\*|__)?' + heading + '[:\\*\\s]*\\n?([\\s\\S]*?)(?=(?:\\n(?:#{1,3}\\s*|\\*\\*|__)?(?:Что происходит|Что уже сделано|Что будет дальше|Нужно ли что-то|План|Следующий этап|Next steps|Action required)|$))', 'i');
      const m = text.match(regex);
      if (m) return m[0].trim();
    }
    return null;
  }

  const whatNext = extractSection(['Что будет дальше', 'План на следующий шаг', 'Следующий этап', 'Next steps', 'What next']);
  const neededFromOwner = extractSection(['Нужно ли что-то от владельца', 'Требуется ли что-то от владельца', 'От владельца', 'Owner action required', 'Action required']);

  const lowerText = text.toLowerCase();
  const lowerNeeded = (neededFromOwner || '').toLowerCase();

  // SCENARIO 3: COMPANION_BLOCKER
  const blockerKeywords = [
    'критический блокер',
    'критическая ошибка',
    'фатальная ошибка',
    'невозможно продолжить',
    'нарушение спецификации',
    'отказ от выполнения',
    'заблокировано до исправления',
    'critical blocker',
    'fatal error',
    'cannot proceed'
  ];
  const hasBlocker = blockerKeywords.some(kw => lowerText.includes(kw));
  if (hasBlocker) {
    return {
      scenario: 'COMPANION_BLOCKER',
      reason: 'Обнаружен критический блокер или отказ выполнения в тексте ответа.',
      whatNext,
      neededFromOwner,
      rawSummary: (neededFromOwner || text).slice(0, 500)
    };
  }

  // SCENARIO 1: OWNER_GATE
  const gateKeywords = [
    'подтверд',           // подтвердить, подтверждение, подтвердите, подтверждаю
    'согласов',           // согласовать, согласование
    'не создаю до',       // "Новый Action Packet до подтверждения не создаю"
    'до подтверждения',
    'ожидаю решения',
    'жду решения',
    'выберите вариант',
    'уточните',
    'требуется решение',
    'требуется подтверждение',
    'нужно подтвердить',
    'нужно только подтвердить',
    'жду вашего ответа',
    'жду подтверждения',
    'действие владельца',
    'действия владельца',
    'полезное действие',
    'ручн',               // ручная проверка, ручное тестирование, ручное участие, ручную приемку
    'owner gate',
    'release gate',
    'запустить текущий candidate',
    'запустите текущий candidate',
    'проверить candidate',
    'проверить в реальной работе',
    'финализация v1 закрыта',
    'новый action packet сейчас не нужен',
    'новый пакет сейчас не нужен',
    'пакет сейчас не нужен'
  ];

  const strippedNeeded = lowerNeeded.replace(/#{1,3}\s*нужно ли что-то от владельца/i, '').trim();
  const hasGateInNeeded = gateKeywords.some(kw => lowerNeeded.includes(kw));
  const hasGateInText = gateKeywords.some(kw => lowerText.includes(kw));

  // Explicit statement by companion that no new packet is created / stage complete / owner gate
  const explicitNoPacketOrGate = /новый\s+(?:agentic_action_packet|action\s*packet|пакет)\s+(?:сейчас\s+)?не\s+(?:нужен|требуется|формирую|создаю)|не\s+формирую\s+новый\s+пакет|пакет\s+не\s+формирую|крупная\s+финализация\s+v1\s+закрыта|переход\s+к\s+(?:release\s+)?owner\s+gate/i.test(lowerText);

  // Purely "no action" check: strictly match short negative statements without instructions
  const isPurelyNoAction = /^(?:нет|не\s+требуется|ничего\s+не\s+(?:нужно|требуется)|никаких\s+действий(?:\s+не\s+требуется)?)[.!]?$/i.test(strippedNeeded);

  const isPacketHandoffOnly = /только\s+передать|передать\s+(этот\s+|новый\s+)?(agentic_action_packet|экшн-пакет|action\s*packet|\.json)|через\s+action\s*bridge/i.test(lowerNeeded) && !explicitNoPacketOrGate;

  if (isPacketHandoffOnly) {
    return {
      scenario: 'LLM_OMISSION',
      reason: 'Компаньон указал на передачу Action Packet через Action Bridge, но файл пакета ещё не был получен или выгружен.',
      whatNext,
      neededFromOwner,
      rawSummary: (neededFromOwner || text).slice(0, 500)
    };
  }

  // SCENARIO 0: CONTEXT_REUPLOAD_REQUIRED
  // Companion explicitly notes that the context archive / attachment is missing, inaccessible, or requests re-attaching the file
  const isReuploadRequested = /(?:архив|файл|контекст|latest_context|\.zip).*(?:не\s+доступен|не\s+найден|не\s+вижу|отсутствует|нет\s+в\s+файлах|повторно\s+прикрепить|прикрепите\s+повторно|прикрепить\s+файл|переприкрепить)/i.test(lowerText) ||
    /(?:не\s+доступен\s+в\s+переданных|среди\s+доступных.*последний|только\s+повторно\s+прикрепить|прикрепить\s+файл.*\.zip)/i.test(lowerText) ||
    /(?:re-?upload|file\s+not\s+found|archive\s+not\s+found|attachment\s+missing)/i.test(lowerText);

  if (isReuploadRequested) {
    return {
      scenario: 'CONTEXT_REUPLOAD_REQUIRED',
      reason: 'Компаньон сообщил, что переданный архив фактически отсутствует или недоступен во вложениях, и запросил повторное прикрепление файла.',
      whatNext,
      neededFromOwner,
      rawSummary: (neededFromOwner || text).slice(0, 500)
    };
  }

  const isContextZipRequest = /(?:нужен|приложить|достаточно\s+приложить|передать|пришлите|прикрепите|прикрепить|ожидаю).*(?:latest_context|контекст|архив|контекст-пак|\.zip)/i.test(lowerNeeded) ||
    /(?:нужен\s+(?:следующий|актуальный|новый|свежий)?\s*latest_context|достаточно\s+приложить\s+именно\s+его|приложить.*архив\s+контекста|нужен\s+следующий\s+latest_context)/i.test(lowerText);

  if (isContextZipRequest) {
    return {
      scenario: 'READY_FOR_CONTEXT',
      reason: 'Компаньон запросил актуальный контекстный архив (LATEST_CONTEXT) для анализа результатов выполнения.',
      whatNext,
      neededFromOwner,
      rawSummary: (neededFromOwner || text).slice(0, 500)
    };
  }

  if (explicitNoPacketOrGate) {
    return {
      scenario: 'OWNER_GATE',
      reason: 'Компаньон зафиксировал завершение этапа разработки и переход к проверке владельцем (OWNER GATE). Создание новых пакетов приостановлено.',
      whatNext,
      neededFromOwner,
      rawSummary: (neededFromOwner || whatNext || text).slice(0, 500)
    };
  }

  if (hasGateInNeeded) {
    return {
      scenario: 'OWNER_GATE',
      reason: 'Компаньон запросил подтверждение, выбор направления или действие владельца перед созданием пакета.',
      whatNext,
      neededFromOwner,
      rawSummary: (neededFromOwner || whatNext || text).slice(0, 500)
    };
  }

  if (hasGateInText && !isPurelyNoAction && !neededFromOwner) {
    return {
      scenario: 'OWNER_GATE',
      reason: 'Компаньон запросил подтверждение, выбор направления или решение владельца перед созданием пакета.',
      whatNext,
      neededFromOwner,
      rawSummary: (whatNext || text).slice(0, 500)
    };
  }

  if (neededFromOwner && !isPurelyNoAction && strippedNeeded.length > 10) {
    return {
      scenario: 'OWNER_GATE',
      reason: 'В секции «Нужно ли что-то от владельца» содержатся требования или вопросы к владельцу.',
      whatNext,
      neededFromOwner,
      rawSummary: neededFromOwner.slice(0, 500)
    };
  }

  // SCENARIO 2: LLM_OMISSION
  return {
    scenario: 'LLM_OMISSION',
    reason: 'Компаньон не сформировал Action Packet, хотя действий от владельца не требуется (пропуск генерации/скрипта).',
    whatNext,
    neededFromOwner,
    rawSummary: text.slice(-400)
  };
}

export async function dismissBlockingPopups(conn) {
  try {
    const res = await conn.send('Runtime.evaluate', {
      expression: `(() => {
        const dialogs = Array.from(document.querySelectorAll('[role="dialog"], [role="alertdialog"], div.popover'));
        for (const dlg of dialogs) {
          const t = dlg.innerText || '';
          if (t.includes('Вы уже загрузили этот файл') || t.includes('already uploaded this file') || t.includes('Попробуйте загрузить')) {
            const okBtn = dlg.querySelector('button');
            if (okBtn) {
              okBtn.click();
              return { dismissed: true, type: 'duplicate_file_dialog' };
            }
          }
          if (t.includes('Понятно') || t.includes('Got it') || t.includes('Dismiss')) {
            const btns = Array.from(dlg.querySelectorAll('button'));
            const dismissBtn = btns.find(b => (b.innerText || '').match(/^(OK|ОК|Понятно|Got it|Dismiss|Закрыть|Close)$/i));
            if (dismissBtn) {
              dismissBtn.click();
              return { dismissed: true, type: 'info_modal' };
            }
          }
        }
        return { dismissed: false };
      })()`,
      returnByValue: true
    });
    if (res.result?.value?.dismissed) {
      logMessage(`[Watchdog] 🛡️ Обнаружено и автоматически закрыто модальное окно: ${res.result.value.type}`);
      return true;
    }
  } catch {}
  return false;
}

const companionTrafficErrorState = {};

export async function handleCompanionServerErrorOrRetry(conn, projectKey) {
  try {
    const res = await conn.send('Runtime.evaluate', {
      expression: `(() => {
        const bodyText = document.body.innerText || '';
        const isTrafficError = /servers are experiencing high traffic|please try again in a minute/i.test(bodyText);
        const isGenericError = /something went wrong|an error occurred|there was an error generating a response/i.test(bodyText);

        if (!isTrafficError && !isGenericError) {
          return { errorDetected: false };
        }

        const allButtons = Array.from(document.querySelectorAll('button'));
        const retryBtn = allButtons.find(b => {
          const t = ((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '')).toLowerCase();
          return t.includes('try again') || t.includes('повторить') || t.includes('regenerate');
        });

        return {
          errorDetected: true,
          errorType: isTrafficError ? 'HIGH_TRAFFIC' : 'SERVER_ERROR',
          hasRetryButton: !!retryBtn
        };
      })()`,
      returnByValue: true
    });

    const info = res.result?.value;
    if (!info?.errorDetected) {
      if (companionTrafficErrorState[projectKey]) {
        delete companionTrafficErrorState[projectKey];
      }
      return false;
    }

    const now = Date.now();
    if (!companionTrafficErrorState[projectKey]) {
      companionTrafficErrorState[projectKey] = {
        firstSeen: now,
        lastAttempt: 0,
        type: info.errorType
      };
      logMessage(`[Companion Watchdog] ⚠️ Обнаружена ошибка ChatGPT (${info.errorType}) для ${projectKey}. Ожидание 45с перед автоповтором...`);
      sendTelegramNotification(
        `⏳ <b>CHATGPT: ПЕРЕГРУЗКА СЕРВЕРОВ OPENAI (${projectKey})</b>\n\n` +
        `• <b>Ошибка:</b> Our servers are experiencing high traffic right now.\n` +
        `• <b>Действие:</b> Автоматическое нажатие 'Try again' через 45-60 секунд.`,
        600000
      );
      return true;
    }

    const state = companionTrafficErrorState[projectKey];
    // Wait at least 45 seconds from first discovery and 30 seconds between click attempts
    if (now - state.firstSeen >= 45000 && now - state.lastAttempt >= 30000) {
      state.lastAttempt = now;
      logMessage(`[Companion Watchdog] 🔄 Время ожидания истекло. Нажимаем кнопку 'Try again' для ${projectKey}...`);

      const clickRes = await conn.send('Runtime.evaluate', {
        expression: `(() => {
          const allButtons = Array.from(document.querySelectorAll('button'));
          const retryBtn = allButtons.find(b => {
            const t = ((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '')).toLowerCase();
            return t.includes('try again') || t.includes('повторить') || t.includes('regenerate');
          });
          if (retryBtn) {
            retryBtn.click();
            return { clicked: true };
          }
          return { clicked: false };
        })()`,
        returnByValue: true
      });

      if (clickRes.result?.value?.clicked) {
        logMessage(`[Companion Watchdog] ✅ Кнопка 'Try again' успешно нажата для ${projectKey}!`);
        sendTelegramNotification(
          `🔄 <b>CHATGPT: АВТОМАТИЧЕСКИЙ ПОВТОР ВЫПОЛНЕН (${projectKey})</b>\n\n` +
          `• <b>Действие:</b> Нажата кнопка 'Try again' / 'Повторить'.\n` +
          `• <b>Статус:</b> Ожидание генерации нового ответа ассистента.`,
          300000
        );
        delete companionTrafficErrorState[projectKey];
        return true;
      } else {
        logMessage(`[Companion Watchdog] ⚠️ Кнопка 'Try again' не найдена для ${projectKey}.`);
        if (now - state.firstSeen >= 90000) {
          logMessage(`[Companion Watchdog] 🔄 Мягкая синхронизация вкладки ${projectKey} после 90с застрявшей ошибки...`);
          await conn.reload();
          delete companionTrafficErrorState[projectKey];
        }
      }
    }
  } catch (err) {
    logMessage(`[Companion Watchdog Error] ${projectKey}: ${err.message}`);
  }
  return false;
}

export async function submitPromptToTab(conn, promptText) {
  // Unbound legacy nudges cannot send. Existing owner send/reply CLI routes below
  // carry a durable operation and exact current context binding.
  throw new Error('BOUND_TRANSPORT_REQUIRED');
}

export async function sendPromptToCompanion(projectKey, promptText, options = {}) {
  return transportV2.ownerReply(projectKey, promptText, options);
}

export async function pullActionPacket(projectKey, options = {}, candidateName = null) {
  // Disk, DOM, UI download and interpreter API all end at DurableTransport.ingress.
  return transportV2.pull(projectKey);
}

export async function pushLatestContext(target, options = {}) {
  const projectKey = detectProjectKey(target);
  if (projectKey) {
    const config = loadConfig();
    const comp = config.browser?.companions?.[projectKey];
    if (comp && isProjectExecuting(projectKey, comp) && !options.force) {
      return { ok: false, reason: 'PROJECT_CURRENTLY_EXECUTING' };
    }
    let zip = typeof target === 'string' && target.endsWith('.zip') && fs.existsSync(target) ? target : getLatestHandoffZip(projectKey);
    if (comp && checkProjectNeedsHandoffExport(projectKey, comp, null, zip)) {
      await triggerHandoffExport(projectKey, comp);
      zip = getLatestHandoffZip(projectKey);
    }
    if (zip) return transportV2.push(zip, options);
  }
  return transportV2.push(target, options);
}

function writeBridgeHeartbeat() {
  try {
    const helper=path.join(path.dirname(recoveryFileURLToPath(import.meta.url)),'native_health.py');
    recoveryExecFileSync(runtimePath('AGENTIC_PYTHONW'),[helper,'--command','heartbeat','--pid',String(process.pid)],{encoding:'utf8',timeout:10000,windowsHide:true,maxBuffer:65536,env:{...process.env,PYTHONUTF8:'1'}});
  } catch { logMessage('[Health HOLD] Bridge heartbeat identity unavailable'); }
}

const projectActivityTracker = {};

export async function watch(options = {}) {
  do {
    // Re-read configuration and project allowlist every cycle; never retain a
    // removed lane or use a filename's timestamp as authorization.
    writeBridgeHeartbeat();
    const config = loadConfig();
    const companionEntries = Object.entries(config.browser?.companions || {});
    await Promise.allSettled(companionEntries.map(async ([projectKey, comp]) => {
      if (isProjectInStandby(projectKey)) return;
      let conn;
      try {
        conn = await connectToTab(comp.urlPattern);
        await dismissBlockingPopups(conn);
        await handleCompanionServerErrorOrRetry(conn, projectKey);
        const result = await transportV2.tick(projectKey, conn);
        let zip = getLatestHandoffZip(projectKey);
        if (checkProjectNeedsHandoffExport(projectKey, comp, result, zip)) {
          await triggerHandoffExport(projectKey, comp);
          zip = getLatestHandoffZip(projectKey);
        }
        const executing = isProjectExecuting(projectKey, comp);
        if (!executing) {
          checkAndAutoRotateProject(projectKey, comp);
          const isFailedUnproven = result.state === 'FAILED' && result.hold_reason === 'SEND_EXPIRED_NOT_PROVEN';
          if (isFailedUnproven) {
            logMessage(`[Transport Watchdog] ⏸️ ${projectKey}: state=FAILED hold=SEND_EXPIRED_NOT_PROVEN. Повторная отправка заблокирована во избежание дубликатов. Запуск soft reload...`);
            await conn.reload();
          }
          const canPushContext = ['NO_DISPATCH','WORK_COMPLETE','CONTEXT_REQUIRED','PREPARED'].includes(result.state) ||
            (result.state === 'FAILED' && !isFailedUnproven);
          if (canPushContext) {
            if (zip) {
              await pushLatestContext(zip);
              if (comp.pendingNextConversationId) {
                const targetCid = comp.pendingNextConversationId;
                logMessage(`[Handover] Context pushed to companion. Executing pending conversation handover for ${projectKey} -> ${targetCid}...`);
                const rotateScript = path.join(path.dirname(recoveryFileURLToPath(import.meta.url)), 'rotate_active_dialog.py');
                let pythonExe = runtimePath('AGENTIC_PYTHON');
                if (!pythonExe || !fs.existsSync(pythonExe)) {
                  pythonExe = (process.env.LOCALAPPDATA || 'C:\\Users\\Администратор\\AppData\\Local') + '\\Programs\\Python\\Python314\\python.exe';
                }
                try {
                  recoveryExecFileSync(pythonExe, [rotateScript, projectKey, targetCid], {
                    encoding: 'utf8', timeout: 45000, windowsHide: true
                  });
                  cachedConfigMtime = 0;
                  cachedConfig = null;
                } catch (e) {
                  logMessage(`[Handover Error] Direct execution failed: ${e.message}`);
                }
              }
            }
          }
        }

        // Stalled Turn Watchdog: detects silent freezes when project is not executing and state does not progress
        const now = Date.now();
        if (!projectActivityTracker[projectKey]) {
          projectActivityTracker[projectKey] = {
            lastState: result.state,
            lastActivity: now,
            lastAlert: 0
          };
        }
        const tracker = projectActivityTracker[projectKey];
        const isGenerating = Boolean(result.generating || result.record?.generating);
        if (executing || isGenerating || result.state !== tracker.lastState) {
          tracker.lastActivity = now;
          tracker.lastState = result.state;
        }

        // 1. Silent OpenAI Freeze Watchdog: if state is SENT but generation never started (> 240s)
        const silentFreezeTimeoutMs = config.browser?.watchdog?.silentFreezeTimeoutMs || 240000;
        const isSilentFreeze = (result.state === 'SENT' && !isGenerating && (now - tracker.lastActivity >= silentFreezeTimeoutMs));

        if (!executing && isSilentFreeze && (now - tracker.lastAlert >= silentFreezeTimeoutMs)) {
          tracker.lastAlert = now;
          const freezeSec = Math.round((now - tracker.lastActivity) / 1000);
          logMessage(`[Watchdog] ⚡ Зафиксирован тихий сбой OpenAI для ${comp.name} (${projectKey}): SENT без генерации > ${freezeSec}с. Запуск auto-nudge...`);

          sendTelegramNotification(
            `⚡ <b>WATCHDOG: АВТО-РАЗБЛОКИРОВКА OPENAI (${comp.name})</b>\n\n` +
            `• <b>Состояние:</b> Сообщение в статусе <code>SENT</code>, но генерация не началась за ${freezeSec}с.\n` +
            `• <b>Действие:</b> Автоматический перезапуск запроса через CDP (Edit ➔ Send).`,
            silentFreezeTimeoutMs
          );

          const nudged = await autoNudgeSilentFreeze(conn, comp);
          if (nudged) {
            tracker.lastActivity = now;
          }
        }

        // 2. Regular Stalled Turn Watchdog
        const maxGenTimeout = config.browser?.watchdog?.maxGenerationTimeoutMs || 1800000;
        const defaultStalledTimeout = config.browser?.watchdog?.stalledTurnTimeoutMs || 900000;
        const stalledTimeout = (result.state === 'SENT' && isGenerating) ? maxGenTimeout : defaultStalledTimeout;

        let isAwaitingOwner = result.state === 'WAIT_OWNER';
        if (!isAwaitingOwner && comp?.projectPath) {
          try {
            const naP = path.join(comp.projectPath, '.agy', 'NEXT_ACTION.json');
            if (fs.existsSync(naP)) {
              isAwaitingOwner = JSON.parse(fs.readFileSync(naP, 'utf8'))?.owner_decision_required === true;
            }
          } catch {}
        }
        if (!executing && !isGenerating && !isAwaitingOwner && (now - tracker.lastActivity >= stalledTimeout) && (now - tracker.lastAlert >= stalledTimeout)) {
          tracker.lastAlert = now;
          const stalledMinutes = Math.round((now - tracker.lastActivity) / 60000);
          logMessage(`[Watchdog] ⚠️ Зафиксирован простой цикла для ${comp.name} (${projectKey}) > ${stalledMinutes} мин (состояние: ${result.state}).`);

          const triggered = triggerSupervisorDiagnostic(
            projectKey,
            comp,
            result.state,
            stalledMinutes,
            result.hold_reason ? `Hold reason: ${result.hold_reason}` : ''
          );

          const actionText = triggered
            ? `🤖 <b>Запущен диагностический агент Antigravity</b> для анализа причин остановки и восстановления цикла.`
            : `Выполняется автоматическая диагностика, перепроверка экспорта и обновление вкладки.`;

          sendTelegramNotification(
            `⚠️ <b>WATCHDOG: ПРОСТОЙ ЦИКЛА (${comp.name})</b>\n\n` +
            `• <b>Состояние транспорта:</b> <code>${result.state}</code>\n` +
            `• <b>Время без активности:</b> ${stalledMinutes} мин.\n` +
            `• <b>Действие:</b> ${actionText}`,
            stalledTimeout
          );

          if (config.browser?.watchdog?.autoReloadOnFreeze !== false && !['WAIT_OWNER', 'CONTEXT_REQUIRED', 'SENT'].includes(result.state) && !isGenerating) {
            try {
              const clickRetryExpr = `(() => {
                const btns = Array.from(document.querySelectorAll('button'));
                const retryBtn = btns.find(b => {
                  const t = (b.innerText || '').trim().toLowerCase();
                  return t.includes('попробовать снова') || t.includes('retry') || t.includes('повторить');
                });
                if (retryBtn) { retryBtn.click(); return true; }
                return false;
              })()`;
              const retryRes = await conn.send('Runtime.evaluate', { expression: clickRetryExpr, returnByValue: true }, 3000);
              if (retryRes?.result?.value) {
                logMessage(`[Watchdog] 🔄 Нажата кнопка Retry/Повторить для ${comp.name}`);
              } else {
                logMessage(`[Watchdog] ℹ️ conn.reload() пропущен для ${comp.name} во избежание Cloudflare/OpenAI 429 ("босс").`);
              }
            } catch (err) {
              logMessage(`[Watchdog Error] Ошибка проверки retry кнопки: ${err.message}`);
            }
          }
        }
      } catch (error) {
        logMessage('[Transport HOLD] ' + projectKey + ': ' + (error.code || error.message));
        if (conn?.ws) {
          try { conn.close(); } catch {}
        }
      } finally {
        if (options.once) {
          try { conn?.close(); } catch {}
        }
      }
    }));
    writeBridgeHeartbeat();
    if (typeof global.gc === 'function') {
      try { global.gc(); } catch {}
    }
    if (options.once) break;
    await new Promise(resolve => setTimeout(resolve, options.intervalMs || config.browser?.pollIntervalMs || 5000));
  } while (true);
}

// CLI runner
if (process.argv[1] && process.argv[1].replace(/\\/g, '/').endsWith('companion_bridge.js')) {
  const command = process.argv[2] || 'watch';
  (async () => {
    try {
      if (command === 'watch') {
        const once = process.argv.includes('--once');
        await watch({ once });
      } else if (command === 'push') {
        const target = process.argv[3] || 'vitalis';
        const force = process.argv.includes('--force');
        const res = await pushLatestContext(target, { force });
        console.log("Push result:", JSON.stringify(res, null, 2));
      } else if (command === 'pull') {
        const proj = process.argv[3] || 'h10';
        const res = await pullActionPacket(proj);
        console.log("Pull result:", JSON.stringify(res, null, 2));
      } else if (command === 'send' || command === 'reply') {
        const proj = process.argv[3] || 'vitalis';
        let text = '';
        const fileIdx = process.argv.indexOf('--file');
        if (fileIdx !== -1 && process.argv[fileIdx + 1]) {
          text = fs.readFileSync(process.argv[fileIdx + 1], 'utf-8');
        } else {
          text = process.argv.slice(4).join(' ');
        }
        if (!text || !text.trim()) {
          throw new Error('Текст сообщения пуст.');
        }
        const epochIdx = process.argv.indexOf('--expected-epoch');
        const operationIdx = process.argv.indexOf('--operation-id');
        const expectedEpoch = epochIdx === -1 ? undefined : Number(process.argv[epochIdx + 1]);
        const operationId = operationIdx === -1 ? undefined : process.argv[operationIdx + 1];
        const res = await sendPromptToCompanion(proj, text.trim(), {expectedEpoch, operationId});
        console.log(JSON.stringify(res));
      } else if (command === 'test-all') {
        console.log('=== Запуск тихой выгрузки по обоим проектам ===');
        await pullActionPacket('h10');
        await pullActionPacket('vitalis');
      } else if (command === 'status') {
        console.log('Конфигурация:', {projects:Object.keys(loadConfig().browser?.companions || {}),transport:'v2'});
        console.log('Обработанные входящие пакеты (seen):', loadSeenPackets());
        console.log('Отправленные исходящие архивы (pushed):', loadPushedZips());
      } else {
        console.log('Использование: node scripts/companion_bridge.js [watch | push <vitalis|h10|path> | pull <h10|vitalis> | send <vitalis|h10> [--file <path> | <text>] | test-all | status]');
      }
    } catch (err) {
      logMessage(`[CLI Error] ${err.message}`);
      process.exit(1);
    }
  })();
}

