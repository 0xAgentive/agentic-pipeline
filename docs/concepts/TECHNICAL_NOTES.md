# Technical Notes

## Verification

LLM text is not proof. Proof is exit code, test result, diff, screenshot, log, or reproducible artifact.

## Fastpatch

`/fastpatch` is script-gated:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1
```

## Codebase Memory on Windows

Use `cmd.exe /d /c C:\Users\Public\mcp-wrappers\codebase-memory-mcp.cmd` in MCP config. Use `scripts/cbm-index-current-rpc.cjs` for indexing. Do not use CLI `index_repository` as canonical on Windows.
