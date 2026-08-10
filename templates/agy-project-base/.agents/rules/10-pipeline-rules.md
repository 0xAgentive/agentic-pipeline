# Pipeline Rules

- Read current `.agy` authority before substantial work.
- Never write before `Test-ExecutionLease.ps1 -BeforeWrite` passes.
- Use the one immutable owner brief; do not create another semantic task pack inside the same work item.
- Audit once comprehensively before repair and publish stable finding IDs.
- Repair related findings in grouped batches using `REPAIR_DELTA.json`.
- Respect the convergence budget and scientific stage firewall.
- Record actual commands, exit codes, changed files, artifacts and material findings.
- Use `Compile-ResultAuthority.ps1` for closure; do not hand-author conflicting statuses. Invoke it only with `pwsh -NoProfile -NonInteractive -File`, exact `-ProjectRoot`, a fresh bound `-VerificationReceiptPath`, and a bounded `-TimeoutSeconds`; never use nested `pwsh -Command` or omit the receipt.
- A closure receipt must bind the current work item, goal epoch, branch, HEAD, active execution lease and current candidate-manifest hash. Every required test must bind its completed timestamp and exact portable, non-reparse evidence path under `.agy/verification/**`, SHA-256 and byte size; capability, credential, secret, token, password and private-key names are forbidden.
- Treat `.agy/VERIFICATION_RECEIPT.json`, `.agy/CLOSURE_STATE.json`, `.agy/RUN_RESULT.json`, and `.agy/NEXT_ACTION.json` as one transactional publication. Read or announce closure only after the compiler reports completion.
- Stop only at accepted closure, verification-debt closure or one material hard stop.
