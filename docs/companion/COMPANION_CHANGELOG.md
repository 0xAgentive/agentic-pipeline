# Companion changelog

## 1.2.9 — Source-Immutable Runtime Finalization

- External Action Packets no longer contain the local capability secret; authorization is injected only by the installed Bridge.
- Packet import validates project, work item, goal epoch, ecosystem version, expiry and replay identity before local materialization.
- Context Handoff exports safe progress authority while excluding raw packets and Bridge capability files.
- Companion deployment and restart bootstrap are manifest-bound, allowlisted and secret-free.

## 1.2.8 — Unified Owner-Autonomous Execution

- Unified all owner-visible component versions to 1.2.8.
- Replaced downloadable ZIP action packets with single `.json` packets accepted by the Antigravity file picker and imported automatically by the local bridge.
- Added exact runtime-truth markers, plain-language owner output and fail-closed action-packet validation.
- Removed numerical repair-budget authorization from active policy.

Historical Companion files are under `docs/companion/archive/`.
