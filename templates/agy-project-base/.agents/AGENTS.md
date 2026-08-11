# Runtime Agent Instructions

Framework Runtime Version: `1.2.24`
Primary runtime: Google Antigravity
Hook mode: active project-local enforcement

## Core operating rule

The owner approves a product goal once. Routine implementation, audit correction, verification retry and current-scope repair continue automatically. Routine work continues automatically while measurable progress is observed. Internal iteration counts never require owner approval. Stop only for a true owner decision or repeated no-progress.

## Current authority

Read `.agy/ACTION_PACKET_RECEIPT.json`, `.agy/WORK_ITEM.json`, `.agy/EXECUTION_SCOPE.json`, `.agy/EXECUTION_LEASE.json`, `.agy/STAGE_FIREWALL.json`, `.agy/PROGRESS_STATE.json`, `.agy/NEXT_ACTION.json`, `.agy/FINDINGS.json`, `.agy/AUDIT_COVERAGE_MATRIX.json`, `.agy/CANDIDATE_MANIFEST_STATUS.json` and `.agy/RUNTIME_HANDSHAKE.json` when present.

## Before writes

- Start a new owner goal through `Start-WorkItemTransaction.ps1`.
- Perform read-only discovery.
- Bind exact paths and allowed commands through `Bind-ExecutionScopeTransaction.ps1`.
- Active `PreToolUse` hooks deny file writes and mutation commands outside that lease.
- A scientific-stage firewall must be active for health/scientific work.

## Convergence

Continue while there is measurable progress. `Register-Progress.ps1` tracks product findings, tests and candidate identities. Iteration counts are informational only. Two identical/no-progress outcomes trigger one hard stop; they never trigger an owner request for more repair permission.

Owner interaction is permitted only for scope/requirements change, destructive or irreversible action, publication/release, credentials/private data/paid network access, material risk acceptance, normative protocol change, or a genuinely unavailable required capability.

## Findings and audit

Finding and audit artifacts are fail-closed. Unknown materiality, missing lifecycle, incomplete declared coverage or candidate identity mismatch blocks closure and routes an internal control-plane correction. Malformed findings are never silently ignored.

## Owner communication

Technical details belong in the action packet and machine artifacts. Owner-facing comments use plain Russian and answer only: what is happening, what is done, what happens next, and whether the owner must act. Do not show hashes, paths, lease IDs, finding IDs, epochs, schemas or internal counters unless the owner asks.

## Tool and route behavior

- `/nextphase`: initial implementation candidate.
- `/auditphase`: read-only comprehensive or final audit.
- `/fixcritical`: current-scope repair; no numerical limit.
- `/fastpatch`: script-gated low-risk UI patch.
- `/shipcheck`, `/githubprepare`, `/githubsync`: release only.

A Stop hook may continue the same approved work item automatically when `.agy/NEXT_ACTION.json` permits it. It must stop on a true owner decision, repeated no-progress, wrong project, unsafe/destructive action, or missing required capability.
