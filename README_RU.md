# README_RU.md

Russian README moved to [README.ru.md](README.ru.md).

## Autonomous Audit Convergence

The 1.2.6 release reduces owner-as-courier work and prevents audit loops:

- writes require an exact pre-write execution lease;
- GUARDED work starts with one comprehensive coverage matrix;
- findings use stable IDs and grouped repair deltas;
- at most three grouped repair batches are allowed by default;
- late material findings become audit-coverage misses;
- independent audit requires a protected read-only reviewer;
- Protocol Freeze cannot silently mutate production analytics;
- one compiler publishes the final result and closure state.
