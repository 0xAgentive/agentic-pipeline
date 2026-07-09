# Machine Learning System Design Applicability

Agentic Pipeline controls a nondeterministic executor: an agent that can sound confident and still be wrong. ML/system design principles are therefore useful.

## Adopt

- Problem frame before high-risk work.
- Cost-of-mistake risk model.
- Living requirements and requirement drift.
- Baseline before improvement claims.
- Workflow behavior evals.
- Error analysis and failure taxonomy.
- Artifact provenance: path, size, SHA-256, contents.
- Runbooks, ADRs and postmortem templates.
- Context budget: playbook as reference, not hot path.

## Do not adopt literally

- mandatory design doc for every tiny change;
- enterprise RACI for every personal project;
- feature stores;
- mandatory A/B testing;
- full ML monitoring stack;
- mandatory API executor;
- mandatory MCP;
- write-capable multi-agent implementation.

## Adoption levels

### Level 1 — simple project

README, workflows, PHASE_STATUS, basic checks.

### Level 2 — important project

Add evidence, artifact index and requirement drift.

### Level 3 — data / security / publication / health-adjacent

Add product contract, risk register, report/security/visual gates.

### Level 4 — framework maintenance

Add evals, metrics, failure taxonomy, runbooks and ADRs.

## Main rule

Add complexity only after a real failure mode or for high-risk work. Do not turn the framework into bureaucracy for small tasks.
