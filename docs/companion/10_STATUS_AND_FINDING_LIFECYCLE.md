# Status and Finding Lifecycle v1.2.16

## Independent status dimensions

```json
{
  "implementation_status": "completed",
  "verification_status": "passed",
  "artifact_status": "complete",
  "audit_status": "passed",
  "acceptance_status": "accepted",
  "scientific_validation_status": "unvalidated",
  "ship_status": "not_applicable"
}
```

## Finding lifecycle

- `open_confirmed`;
- `fixed_unverified`;
- `verified_resolved`;
- `deferred`;
- `accepted_risk`;
- `false_positive`;
- `superseded`.

Every finding has a stable `finding_id`. A finding discovered after the initial comprehensive audit must record `origin: audit_coverage_miss` unless the owner changed the requirement.

Companion output reports only the delta. It must not restate the full brief or entire finding history.

## Scientific stage distinction

Track protocol, algorithm and empirical validation separately. A Protocol Freeze work item cannot modify production analytical behavior without an explicit `algorithm_repair` sub-scope and new analytical baseline.
