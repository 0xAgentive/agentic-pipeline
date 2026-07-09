# How to tell which pipeline a project is using

Open the project root and check:

```powershell
Get-Content .agy\PHASE_STATUS.json -Raw
Get-ChildItem .agents\workflows | Select-Object Name
Get-ChildItem .agents\rules | Select-Object Name
Test-Path .agy\PRODUCT_CONTRACT.json
Test-Path .agy\evidence.ndjson
Test-Path .agy\ARTIFACT_INDEX.ndjson
Test-Path runtime-src
```

If the project has `.agy/PHASE_STATUS.json`, workflows and rules, but no Product Contract, machine evidence, Artifact Index, or runtime-src, it is operating under the current v1.1.x/r4b-style pipeline.

If it has Product Contract, Requirement Delta, Artifact Index, machine evidence and runtime-src, it is migrating to the v1.2 Product Evidence Control Plane.

## When to migrate to v1.2

Do not migrate in the middle of an active feature phase.

A safe moment:
1. current phase is complete;
2. typecheck/test/build pass;
3. `/auditphase` is clean or understood;
4. `/shipcheck` is not blocked;
5. migration is planned through `/planonly` and executed as its own `/nextphase`.

## v1.2 in plain language

v1.2 makes product goals, artifacts, reports, visual checks and evidence verifiable. It is useful for complex projects, but it should not interrupt active product work.
