const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const projectRoot = path.resolve(__dirname, "..");
const logDir = path.join(projectRoot, ".agy", "cbm");
fs.mkdirSync(logDir, { recursive: true });

const cbm = path.join(process.env.LOCALAPPDATA || "", "Programs", "codebase-memory-mcp", "codebase-memory-mcp.exe");
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

function rpcCall(name, args) {
  const request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args || {} } };
  return spawnSync(cbm, [], { cwd: projectRoot, env, input: JSON.stringify(request) + "\n", encoding: "utf8", windowsHide: true, maxBuffer: 1024 * 1024 * 128 });
}

console.log("ProjectRoot=" + projectRoot);
const index = rpcCall("index_repository", { repo_path: projectRoot });
console.log(index.stdout || "");
console.error(index.stderr || "");
if (index.status !== 0) process.exit(index.status || 1);
const list = rpcCall("list_projects", {});
console.log(list.stdout || "");
console.error(list.stderr || "");
process.exit(list.status || 0);
