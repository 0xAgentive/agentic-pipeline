# Protected Reviewer

An audit is independent only when `REVIEWER_ATTESTATION.json` proves:

- read-only reviewer access;
- reviewer context differs from implementation context;
- reviewer root differs from mutable implementation root;
- target HEAD is exact and immutable;
- exact artifact manifest identity is bound;
- implementation, artifact generator and predicates were not authored by the reviewer context.

If these conditions cannot be proven, record audit unavailable and close with verification debt when product verification otherwise passes.
