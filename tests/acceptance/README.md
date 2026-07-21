# Runtime and Flow Restoration Acceptance

This directory is an independent acceptance layer for Agentic Pipeline package candidate 1.2.5 / runtime 1.2.2.

It protects legacy 1.2.4 routing behavior while adding additive Flow Restoration contracts:

- work-item-scoped terminality;
- FLOW, GUARDED and RELEASE routing;
- shadow mode that cannot authorize writes;
- degraded product execution with release commands closed;
- exact execution-scope and compact run-result schemas;
- installation identity derived from `VERSION.json`;
- unchanged legacy golden-case IDs.
