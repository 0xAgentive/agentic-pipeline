# Context Split Policy

The user's system has two products that work together:

1. ChatGPT Project companion pack
2. Antigravity local pipeline repository

They must stay synchronized in intent, but they must not contain the same kind of information.

## ChatGPT Project companion owns

- raw idea clarification;
- product strategy;
- research;
- risk framing;
- requirement drift analysis;
- artifact/log review;
- Agent Task Packs;
- exact prompts for Antigravity;
- high-level migration plans;
- public-facing explanation drafts.

## Antigravity pipeline owns

- executable workspace workflows;
- `.agents` rules;
- hooks/scripts;
- templates;
- validators;
- GitHub-ready docs;
- state-file conventions;
- local project scaffolding;
- deterministic checks.

## Active project owns

- source code;
- project-specific docs;
- project-specific `.agy` state;
- product artifacts;
- test/build evidence.

## Do not put in ChatGPT companion

- large executable scripts;
- project-local absolute paths except as examples;
- active project source code;
- transient logs as permanent knowledge;
- full generated artifact dumps;
- workflow files intended to be executed by Antigravity.

## Do not put in Antigravity runtime

- long research essays;
- full philosophical playbook text;
- historical conversation transcripts;
- domain-specific examples not relevant to most projects;
- unverified assumptions from companion discussion.

## Sync rule

When the framework changes, update both layers deliberately:

- companion: update how tasks are framed and audited;
- pipeline repo: update templates/docs/scripts/workflows;
- active projects: migrate only through a separate planned phase.
