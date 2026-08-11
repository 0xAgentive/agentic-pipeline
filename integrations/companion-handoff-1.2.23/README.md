# Agentic Context Handoff 1.2.23

This integration packages the canonical Context Handoff engine and installs its immutable source transactionally while preserving deployment-owned state.

## Build

Run `Build-AgenticContextHandoffPackage-v1.2.23.ps1` from a clean exact release commit. The ZIP contains:

- canonical immutable engine source;
- `VERSION.json`, `SOURCE_ATTESTATION.json`, and exact `MANIFEST.json` provenance;
- the transactional updater;
- no queue, state, logs, handoffs, release data, active config, cache, ZIP, database, or legacy finalize/fix helpers.

`-AllowDirty` exists only for isolated development verification. The resulting package is marked dirty and the updater rejects it unless `-AllowDevelopmentPackage` is supplied explicitly.

## Install or update

Extract the downloaded release asset and run `Update-AgenticContextHandoff-v1.2.23.ps1` from that extracted directory. The default run is read-only and returns a plan; add `-Apply` to commit it.

The updater:

- validates the complete package file set, hashes, source commit, and source digest before writes;
- creates an external transaction backup and rolls back a partial failure;
- preserves `handoff.config.json`, `queue`, `state`, `logs`, `handoffs`, and `release` as mutable deployment data;
- installs only the manifest-owned immutable source and removes extra active code into the backup;
- activates only token-free authority exports (never raw `ACTION_PACKET.json` or capability files);
- merges the Stop hook without replacing unrelated hooks;
- registers a hidden `wscript.exe` -> `pythonw.exe` worker with no console fallback;
- validates immutable source twice and requires byte-identical hashes;
- performs no writes and creates no backup on an already desired second apply.

`-TaskMode Plan` is reserved for hermetic installation tests; production installation uses the default `Register` mode.
