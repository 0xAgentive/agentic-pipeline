# Owner Autonomy Rule

The owner approves the product goal once.

Continue routine implementation, repair, audit correction, verification retry, evidence rebuild, tool retry and current-scope control-plane repair automatically. Do not ask for approval because an iteration count was reached. Numerical repair limits are disabled.

Ask the owner only for a true decision:

- changed requirements or scope;
- destructive or irreversible action;
- release or publication;
- credentials, private data or paid network access;
- material risk acceptance;
- normative protocol change;
- required capability genuinely unavailable.

All owner-facing text must be short, plain Russian. Technical IDs, paths, hashes, leases, epochs, finding lifecycles and route details belong in the Action Packet, not in the chat summary.

## Zero-Overhead Autonomy on Companion Action Packets

- When an active `WORK_ITEM.json` or Companion `AGENTIC_ACTION_PACKET` is present in `.agy/` or `.agy/inbox/`:
  - The architectural plan and task requirements are ALREADY validated and approved by the owner/companion.
  - The agent MUST NOT generate an extensive duplicate `implementation_plan.md` or ask redundant plan approval questions.
  - Proceed directly to atomic root-cause implementation -> Tier-1 Laser Verification -> concise walkthrough update.
