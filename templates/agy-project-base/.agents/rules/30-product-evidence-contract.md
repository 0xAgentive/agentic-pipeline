# Product Evidence Contract

Before declaring a feature or release ready, verify that:

- current product goal is reflected in `.agy/PRODUCT_CONTRACT.json`;
- unresolved requirement deltas do not block shipcheck;
- required artifacts exist and are indexed;
- evidence is deterministic and machine-readable;
- model prose is not used as verification;
- UI/report/security gates are complete where applicable.

If any required evidence is missing, output `NO-SHIP` or `BLOCKED`.
