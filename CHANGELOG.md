# Changelog

## 1.2.18 — Candidate Manifest Multi-Record Integrity

- Supersedes 1.2.17 without moving or rewriting its public tag or release.
- Fixes candidate-manifest publication so every NUL-delimited Git porcelain record is retained instead of collapsing raw ordered dictionaries to one path.
- Emits UTF-8 machine output for Unicode paths, rejects duplicate or case-colliding status paths, and preserves the exact leased-versus-ambient split.
- Adds an executable modified/deleted/renamed/Unicode multi-record regression to the result-authority transaction suite.
- Rebinds all five ecosystem assets to one immutable 1.2.18 source commit while retaining Action Packet/Bridge schema 1.2.9 and Context engine 4.3.4.

## 1.2.17 — Quiescent Verified Handoff

- Supersedes 1.2.16 without moving or rewriting its public tag or release.
- Replaces prompt-prone result compilation with a fail-fast non-interactive entry point, a bounded worker tree and a project-scoped singleton that coalesces identical requests.
- Publishes the verification receipt, run result, closure state and next action as one journaled transaction with exact rollback and stale-crash recovery.
- Cryptographically binds every required test artifact and candidate file to the active work item, Git HEAD and captured authority inputs, restricted to the non-reparse `.agy/verification/**` subtree.
- Requires Context Handoff to export and validate the exact fresh receipt and evidence before publishing a run, preventing stale pre-repair results from crossing the Stop boundary.
- Adds executable regressions for unsafe invocation, timeout cancellation, concurrent/coalesced compilation, input races, tamper, privacy confinement and rollback.
- Rebinds all five ecosystem assets to one immutable 1.2.17 source commit while retaining schema 1.2.9 and Context engine 4.3.4 compatibility.

## 1.2.16 — Context Handoff Scheduler Idempotence

- Supersedes 1.2.15 without moving or rewriting its public tag or release.
- Uses one bounded task-health wait for Context Handoff idempotent apply and canary verification.
- Tolerates only known transient `Queued`, `Running` and `0x41301` scheduler observations, then requires an enabled `Ready/0` task.
- Fails immediately on terminal non-zero results and times out persistent in-progress states without reporting false success.
- Adds deterministic split-read, timeout and terminal-failure regressions without mutating Scheduled Tasks.
- Rebinds all five ecosystem assets to one immutable 1.2.16 source commit while retaining schema 1.2.9 and Context engine 4.3.4 compatibility.

## 1.2.15 — Cross-Platform Validation and Stop Launch

- Supersedes 1.2.14 without moving or rewriting its public tag or release.
- Launches the Context Stop hook with a first-token-safe direct `powershell.exe -EncodedCommand` command and transactionally removes the obsolete wrapper.
- Rejects over-limit Stop commands before any installation write and binds hermetic cleanup to exact temporary roots and generated handshake leaves.
- Makes runtime, overlay, Action Bridge and hook-contract path confinement executable on both Windows and Ubuntu without weakening Windows-only canaries.
- Runs the complete Distribution Integrity contract on `windows-latest` while retaining the Ubuntu distribution gate.
- Forces Action Bridge stdout and stderr to UTF-8 before JSON or diagnostics so English Windows code pages preserve Unicode paths exactly.
- Rebinds all five ecosystem assets to one immutable 1.2.15 source commit while retaining schema 1.2.9 and Context engine 4.3.4 compatibility.

## 1.2.14 — Context Handoff Command Wrapper

- Supersedes 1.2.13 without moving or rewriting its public tag or release.
- Replaces the fragile direct executable Stop-hook command with an ASCII `.cmd` wrapper that is safe for Unicode and space-containing Windows paths.
- Preserves hook stdin, stdout and exit status through the hidden Windows PowerShell relay while keeping JSON payloads UTF-8.
- Adds executable `cmd.exe` coverage, byte-identical second apply checks and exact transactional rollback coverage.
- Rebinds all five ecosystem assets to one immutable 1.2.14 source commit while retaining schema 1.2.9 compatibility.

## 1.2.13 — Antigravity Hook Working Directory

- Supersedes 1.2.12 without moving or rewriting its public tag or release.
- Resolves project lifecycle-hook commands relative to the `.agents` customization root used as Antigravity's hook working directory.
- Removes the duplicated `.agents/.agents/hooks` path that prevented owner-autonomy hooks from loading their runtime module.
- Adds an executable Stop-hook regression from the exact `.agents` working directory and rejects duplicate handler registration.
- Rebinds all five ecosystem assets to one immutable 1.2.13 source commit while retaining schema 1.2.9 compatibility.

## 1.2.12 — Context Handoff Unicode Launcher

- Supersedes 1.2.11 without moving or rewriting its public tag or release.
- Serializes the hidden Context Handoff launcher as UTF-16LE with BOM so Windows Script Host preserves non-ASCII Python paths.
- Compares the launcher byte-for-byte, keeping a successful second apply write-free and byte-identical.
- Adds an executable `cscript` Unicode-path regression with idempotence and exact transactional rollback coverage.
- Rebinds all five ecosystem assets to one immutable 1.2.12 source commit while retaining schema 1.2.9 compatibility.

## 1.2.11 — Context Handoff Task Quiescence

- Supersedes 1.2.10 without moving or rewriting its public tag or release.
- Quiesces the snapshotted Context Handoff worker before the first installation write.
- Restores and verifies the exact prior task definition and enabled/running state on transactional rollback.
- Requires the replacement worker to be enabled and Ready before a successful update is reported.
- Rebinds all five ecosystem assets to one immutable 1.2.11 source commit while retaining schema 1.2.9 compatibility.

## 1.2.10 — Lossless Legacy Runtime Migration

- Supersedes 1.2.9 without moving or rewriting its public tag or release.
- Adds a transactional, lossless migration for the exact legacy findings shape present in active projects.
- Archives the original findings bytes, rejects unknown legacy variants and restores the complete pre-update state on failure.
- Covers migration, idempotent second apply and rollback with executable Windows regressions.
- Rebinds all five ecosystem assets and deployment receipts to one immutable 1.2.10 source commit.

## 1.2.9 — Source-Immutable Runtime Finalization

- Fixed the recovery overlay that could rewrite six CRLF PowerShell checkout files after otherwise immutable validation.
- Added per-validator tracked-byte snapshots, a one-byte negative probe and Git-attribute-aware candidate materialization.
- Separated native stdout/stderr and made machine Git path parsing NUL-safe.
- Added transactional, allowlisted H10 runtime migration with product-source preservation and idempotent verification.
- Shipped token-free external Action Packets, local Bridge authorization and the full Context Handoff engine.
- Bound all five release assets, deployments and receipts to one immutable 1.2.9 source commit.

## 1.2.8 — Unified Owner-Autonomous Execution

- Unified component versions.
- Replaced ZIP action packets with JSON packets.
- Fixed runtime-truth contract markers.
- Added automatic Downloads-to-Antigravity delivery and manual JSON fallback.
- Enforced fail-closed findings and executable pre-write scope.
