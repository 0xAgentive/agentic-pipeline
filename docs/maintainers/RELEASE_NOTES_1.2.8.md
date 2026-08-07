# Agentic Pipeline 1.2.8 — Unified Owner-Autonomous Execution

This release uses one owner-visible version number for Pipeline, runtime, playbook, Companion, Action Bridge and Context Handoff integration. It adds executable pre-write enforcement, fail-closed finding/audit state, plain-language owner communication and automatic single-JSON Action Packets.

The user downloads `AGENTIC_ACTION_PACKET_*.json`. The local bridge imports it from Downloads automatically; the Antigravity attachment dialog is not part of the normal path.

## Stable operational deployment correction

- Work-item activation now tolerates omitted optional Action Packet fields under PowerShell StrictMode.
- The Windows known-failure validator was rewritten to avoid self-inflicted PowerShell invocation errors.
- Distribution validation separates core safety/runtime failures from advisory documentation and hygiene warnings.
- A Unicode-path operational smoke test now covers work-item activation, runtime-update manifest semantics, and JSON Action Bridge import in one pass.
- Non-material LF/CRLF, documentation-link, and meta-regression warnings no longer block an otherwise core-safe deployment.
