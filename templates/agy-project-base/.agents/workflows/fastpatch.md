---
description: Script-gated micro patch.
---

# /fastpatch

Run first and again after edits:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-FastPatchAllowed.ps1
```

If non-zero, stop and use `/auditphase` or `/nextphase`.
