# Local Control Tools and Action Bridge

Companion creates one `AGENTIC_ACTION_PACKET_*.json`. The local Action Bridge watches Downloads, validates version, time window, replay protection and the per-project capability token, then materializes and atomically imports the task into `.agy/inbox/ACTIVE_ACTION_PACKET/`. Legacy ZIP packets are accepted only for backward compatibility and are not the owner-facing format.

Antigravity's PreInvocation hook injects the pending task once. The runtime activates either a new work item or an exact continuation, then performs read-only executor discovery and binds the exact write scope before product changes.

The web Project cannot write directly to the local filesystem. One download action therefore remains. The owner never copies a long technical task, selects a local project manually, approves a routine repair or handles internal control-plane details.
