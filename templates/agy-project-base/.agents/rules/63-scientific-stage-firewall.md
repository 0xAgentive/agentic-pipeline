# Scientific Stage Firewall

For `stage_profile: protocol_freeze`, allowed changes are protocol, schemas, fixtures, adapters, validators and documentation.

Production analytical behavior is protected. Editing analytical algorithms requires:

- a confirmed `algorithm_repair` finding;
- an explicit bounded sub-scope;
- a new analytical baseline after repair;
- return to Protocol Freeze before analytical validation.

Do not tune algorithms or tolerances from observed validation outcomes.
