# Prompt Compiler and Result Authority

The companion compiles a concise user-visible prompt from a structured task pack. It does not invent runtime facts.

## Prompt compiler rules

- include only the current phase;
- include frozen acceptance criteria;
- include current command from the handshake;
- include evidence level and blocker policy;
- include stop conditions;
- keep detailed contract in JSON/Markdown rather than repeating it inconsistently;
- never hardcode test counts, durations, hashes or artifact sizes before execution.

## Result authority

The final answer must read from `PHASE_RESULT.json` or an equivalent machine-readable result.

Authoritative fields include:

- phase and contract hash;
- status dimensions;
- commands and exit codes;
- changed files;
- artifacts;
- blockers and accepted risks;
- next allowed commands.

If a field is absent, report `unverified`.

Do not reconstruct:

- SHA-256;
- byte size;
- test count;
- duration;
- Git commit;
- next command;
- scientific validation status.

A required child command failure makes the result fail-closed. A wrapper must never emit success after a required non-zero exit code.

## Test-output isolation

Tests must write to temporary roots. If a project claims output isolation, verify additions, modifications, deletions and directory changes around a representative write-producing test.
