const { spawnSync } = require("child_process");

const req = {
  jsonrpc: "2.0",
  id: 1,
  method: "tools/call",
  params: { name: "list_projects", arguments: {} }
};

const result = spawnSync(
  "C:\\Windows\\System32\\cmd.exe",
  ["/d", "/c", "C:\\Users\\Public\\mcp-wrappers\\codebase-memory-mcp.cmd"],
  {
    input: JSON.stringify(req) + "\n",
    encoding: "utf8",
    windowsHide: true,
    maxBuffer: 1024 * 1024 * 64
  }
);

console.log("exit=" + result.status);
console.log("--- stdout ---");
console.log(result.stdout || "");
console.log("--- stderr ---");
console.log(result.stderr || "");

process.exit(result.status || 0);
