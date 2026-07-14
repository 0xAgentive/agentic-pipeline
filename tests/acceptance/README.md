# Runtime Routing Acceptance Contract

These files are an independent acceptance layer for Agentic Pipeline package 1.2.4 / runtime 1.2.1.

They are intentionally committed before the runtime hardening implementation.

During implementation, the following paths are protected and must not be modified:

- `.github/workflows/validate.yml`
- `tests/acceptance/ACCEPTANCE_CONTRACT.json`
- `tests/acceptance/README.md`
- `tests/acceptance/runtime-routing-contract.cjs`
- `tests/acceptance/Test-RuntimeHandshakeAcceptance.ps1`

The acceptance tests are expected to fail against the pre-hardening candidate. The implementation phase must make them pass without changing this contract.

The tests cover:

- objective route authorization;
- command normalization;
- lifecycle routing;
- non-circular shipcheck eligibility;
- inventory provenance and hashing;
- strict runtime identity;
- schema 1.1 validation;
- non-ASCII Windows paths;
- no mutation of an external product fixture.