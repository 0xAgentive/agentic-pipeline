# Frozen Phase Contract and Repair Budget

A phase contract prevents moving goalposts and recursive repair phases.

## Contract fields

- phase ID and version;
- goal and non-goals;
- risk track;
- evidence level;
- allowed and forbidden paths;
- required outputs and checks;
- acceptance criteria;
- blocking conditions;
- non-blocking debt categories;
- repair budget;
- next allowed commands;
- contract hash.

## Freeze rule

The contract is frozen before implementation. After execution starts, criteria cannot be added silently.

A newly discovered issue must be one of:

- `current_phase_blocker`: violates an existing safety, integrity or acceptance condition;
- `next_phase_requirement`: valuable but outside current contract;
- `deferred_debt`: accepted for now;
- `accepted_risk`: explicitly accepted by the user;
- `false_positive`;
- `superseded`.

## Default repair budget

```json
{
  "max_audit_fix_cycles_per_subsystem": 1,
  "max_total_repairs_per_phase": 2,
  "on_budget_exhausted": "human_decision_required"
}
```

Normal path:

```text
implementation -> audit -> one fixcritical -> one verification
```

When exhausted, create a root-cause decision with exactly these options:

- continue repair;
- accept technical debt;
- defer until release;
- redesign subsystem.

The companion must not create another numbered repair phase automatically.
