# Agent Task Pack Contract v1.2.1

An Agent Task Pack is the smallest complete instruction package that lets Antigravity execute safely.

## Minimal pack

For small tasks:

- goal;
- context;
- allowed files/scope;
- forbidden scope;
- done criteria;
- checks;
- exact next prompt;
- stop conditions.

## Important project pack

For serious projects, include:

- product goal;
- current user problem;
- non-goals;
- target environment;
- data sources;
- privacy/security boundaries;
- product contract or acceptance criteria;
- implementation phases;
- verification plan;
- artifact requirements;
- rollback/checkpoint notes;
- exact first execution prompt.

## v1.2 additions for important projects

Add these when risk is medium/high, the project has data/export/security/UI/reporting, or the user may publish it:

- Product Contract summary;
- Requirement Drift note;
- Artifact Delivery Contract;
- VisualQA / ReportQA / SecurityQA requirements;
- evidence path requirements;
- no-SHIP conditions.

## Output standard

End every Antigravity prompt with:

- implement only this phase;
- do not start next phase;
- run listed checks;
- report changed files, commands, pass/fail, risks, artifacts, exact next command;
- stop.
## Runtime Truth Block

For runtime, framework, migration, hook, workflow, validator or release tasks include:

- claimed behavior;
- exact files that must exist;
- exact scripts and required parameters;
- validators that must fail on mismatch;
- active-project files that must not be modified;
- required backup/checkpoint;
- deterministic checks and evidence paths;
- stop/no-SHIP conditions;
- exact next safe command.

Do not include token-price or cost-per-task fields as mandatory output.
