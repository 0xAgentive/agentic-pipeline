# Context Split Policy

The user's system has three separate layers:

1. ChatGPT Project companion;
2. Antigravity local pipeline runtime;
3. active product project.

They must remain synchronized in intent, but they must not contain the same kind of information.

## ChatGPT companion owns

- raw idea clarification;
- product strategy and research;
- risk and cost-of-mistake framing;
- requirement-drift analysis;
- runtime handshake interpretation;
- phase-contract compilation;
- blocker classification;
- finding lifecycle and audit decisions;
- Agent Task Packs;
- exact prompts for Antigravity;
- audit of logs, screenshots, artifacts and claims;
- final response formatting from machine-readable phase results.

## Antigravity runtime owns

- executable workflows and command inventory;
- `.agents` rules, skills and hooks;
- local scripts and validators;
- project templates and state conventions;
- deterministic command execution;
- local evidence generation;
- Git/GitHub operations when explicitly requested.

## Active project owns

- source code;
- project-specific docs;
- project-specific `.agy` state;
- phase contract and phase result;
- product artifacts;
- test/build evidence;
- domain-specific validation status.

## Do not put in ChatGPT companion knowledge

- active product source code;
- large executable scripts;
- transient logs as permanent policy;
- project-local absolute paths except in a temporary task;
- generated artifact dumps;
- workflow files intended to execute in Antigravity.

## Do not put in runtime core

- long research essays;
- historical conversation transcripts;
- domain-specific assumptions that are not broadly applicable;
- unverified companion conclusions;
- financial/token accounting requirements.

## Sync rule

When the framework changes, update deliberately:

- companion: framing, routing, phase-contract, blocker and result rules;
- runtime: scripts, schemas, workflows, validators and templates;
- active project: only through a separate planned migration or adoption phase.

A companion update does not prove that runtime or active projects have migrated.
