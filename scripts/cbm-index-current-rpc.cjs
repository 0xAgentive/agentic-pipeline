const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const projectRoot = path.resolve(__dirname, "..");
const logDir = path.join(projectRoot, ".agy", "cbm");
fs.mkdirSync(logDir, { recursive: true });

const cbm = path.join(
  process.env.LOCALAPPDATA || "",
  "Programs",
  "codebase-memory-mcp",
  "codebase-memory-mcp.exe"
);

if (!fs.existsSync(cbm)) {
  console.error("codebase-memory-mcp.exe not found:", cbm);
  process.exit(2);
}

const env = {
  ...process.env,
  CBM_CACHE_DIR: "C:\\Users\\Public\\codebase-memory-cache",
  CBM_LOG_LEVEL: "error",
  CBM_DIAGNOSTICS: "1"
};

const stamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14);
const summary = path.join(logDir, `cbm-rpc-index-summary-${stamp}.log`);

function log(line) {
  fs.appendFileSync(summary, line + "\n", "utf8");
}

function rpcCall(name, args) {
  const request = {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: { name, arguments: args || {} }
  };

  const result = spawnSync(cbm, [], {
    cwd: projectRoot,
    env,
    input: JSON.stringify(request) + "\n",
    encoding: "utf8",
    windowsHide: true,
    maxBuffer: 1024 * 1024 * 128
  });

  log(`\n## ${name}`);
  log(`request=${JSON.stringify(request)}`);
  log(`exit=${result.status}`);
  log("--- stdout ---");
  log(result.stdout || "");
  log("--- stderr ---");
  log(result.stderr || "");

  return result;
}

console.log("ProjectRoot=" + projectRoot);
console.log("CBM_CACHE_DIR=" + env.CBM_CACHE_DIR);
console.log("Summary log=" + summary);

log("ProjectRoot=" + projectRoot);
log("CBM_CACHE_DIR=" + env.CBM_CACHE_DIR);
log("CBM=" + cbm);

const index = rpcCall("index_repository", { repo_path: projectRoot });
const list = rpcCall("list_projects", {});

console.log("Index exit=" + index.status);
console.log("List exit=" + list.status);
console.log("Summary log=" + summary);

if (index.status !== 0) {
  console.error("index_repository process failed");
  console.error(index.stderr || "");
  process.exit(index.status || 1);
}

const indexText = (index.stdout || "") + "\n" + (index.stderr || "");
if (/repo_path is required/i.test(indexText)) {
  console.error("index_repository returned repo_path error");
  console.error(indexText);
  process.exit(1);
}

console.log("CBM RPC indexing attempt completed.");
console.log("Inspect summary:", summary);
