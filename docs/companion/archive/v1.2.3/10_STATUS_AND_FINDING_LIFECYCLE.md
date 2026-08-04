# Status and Finding Lifecycle

A single `completed` flag is not sufficient.

## Independent status dimensions

```json
{
  "implementation_status": "completed",
  "verification_status": "passed",
  "artifact_status": "partial",
  "audit_status": "pending",
  "acceptance_status": "not_evaluated",
  "scientific_validation_status": "unvalidated",
  "ship_status": "not_applicable"
}
```

Allowed values should be explicit and schema-validated.

## Finding lifecycle

- `open_confirmed`;
- `fixed_unverified`;
- `verified_resolved`;
- `deferred`;
- `accepted_risk`;
- `false_positive`;
- `superseded`.

A finding marked resolved must not remain in the open count.

## Health/scientific distinction

For methodology findings, track separately:

- implementation alignment;
- empirical validation;
- production-use permission.

Example:

```json
{
  "implementation_alignment_status": "resolved",
  "empirical_validation_status": "unvalidated",
  "production_use_status": "blocked"
}
```

Do not infer validation from centralization, documentation or green unit tests.
