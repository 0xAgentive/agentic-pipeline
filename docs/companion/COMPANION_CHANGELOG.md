# Companion changelog

## 1.2.27 — Ecosystem Autonomy and Handoff Alignment

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Preserves valid zero-byte session-delta members and their exact hashes in restart-bootstrap archives.
- Applies strict UTF-8 and privacy checks consistently to empty, staged, existing and extracted members.
- Fails closed when all session deltas are empty without a `NO_NEW_EVENTS` receipt, or when a required authority file is empty.
- Adds an executable Distribution Integrity regression for mixed, receipt-only, all-empty and idempotent-reuse flows.

## 1.2.23 — Exact Handoff Root Entry

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Selects the Context Handoff entry from the exact archive root, so source-snapshot copies cannot create false ambiguity.
- Rejects noncanonical, duplicate, case-colliding and directory-only ZIP members before extraction.
- Adds an executable Distribution Integrity regression for the accepted and rejected archive shapes.

## 1.2.22 — Causal Verification Ordering

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.22.
- Rejects localized or zone-free authority timestamps and refuses a candidate published after any required test began.
- Requires a start timestamp for every required test and preserves verification receipts as compiler-owned, immutable authority inputs.

## 1.2.21 — Hosted Runner Reparse Fixture

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.21.
- Canonicalizes the T66 temporary verification root so hosted Windows runners exercise the same confined path seen by production code.
- Preserves fail-closed reparse rejection and the complete 1.2.20 verification-test authority checks.

## 1.2.20 — Semantic Verification Test Binding

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.20.
- Accepts compiler-canonical empty defaults only when the verification receipt omits the corresponding optional test fields.
- Continues to reject any different non-empty test lineage, evidence identity, timestamp or required-test result before ZIP or clipboard publication.

## 1.2.19 — Atomic Result Authority Publication

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.19.
- Separates compiler-owned `NEXT_ACTION` output from immutable payload authority and verifies its exact intended hash after atomic publication.
- Preserves compatibility with 1.2.18 candidate manifests and proves byte/mtime-identical repeated compilation.

## 1.2.18 — Candidate Manifest Multi-Record Integrity

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.18.
- Preserves every changed Git path in the candidate manifest, including Unicode, rename and deletion records, while keeping ambient paths separate.
- Requires the existing quiescent, verified 1.2.17 handoff authority chain and adds a multi-record false-green regression before publication.

## 1.2.17 — Quiescent Verified Handoff

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.17.
- Requires a fresh, cryptographically bound verification receipt and confined test evidence before Context Handoff can publish a run result.
- Makes result-authority compilation single-instance, bounded, rollback-safe and fail-fast when invoked without its required receipt.

## 1.2.16 — Context Handoff Scheduler Idempotence

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.16.
- Makes Context Handoff idempotent apply robust to bounded transient Windows scheduler states while still requiring final `Ready/0` health.

## 1.2.15 — Cross-Platform Validation and Stop Launch

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.15.
- Uses a first-token-safe encoded Windows PowerShell Stop command and pairs portable validation with full Windows execution coverage.

## 1.2.14 — Context Handoff Command Wrapper

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.14.
- Launches the Context Stop hook through a Unicode-safe transactional `.cmd` wrapper with exact stream and exit-code forwarding.

## 1.2.13 — Antigravity Hook Working Directory

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.13.
- Makes project lifecycle-hook commands executable from Antigravity's `.agents` hook working directory.

## 1.2.12 — Context Handoff Unicode Launcher

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.12.
- Makes the hidden Context Handoff launcher Unicode-safe and byte-idempotent on Windows.

## 1.2.11 — Context Handoff Task Quiescence

- Keeps the independently versioned 1.2.9 token-free Action Packet and local Bridge authorization contract.
- Aligns Companion, runtime, Bridge and Context Handoff asset identity with ecosystem 1.2.11.
- Prevents the installed Context Handoff worker from racing transactional source replacement.

## 1.2.10 — Lossless Legacy Runtime Migration

- Keeps the 1.2.9 token-free Action Packet, local Bridge authorization and safe Context Handoff design.
- Aligns Companion, Bridge and Context Handoff asset identity with the 1.2.10 runtime migration release.
- Preserves exact project authority while legacy findings are migrated transactionally by the local runtime updater.

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
