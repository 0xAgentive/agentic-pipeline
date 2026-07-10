# Project State Profiles

Two explicit initial states are distributed:

- `new-project`: starts at `/specdoc`.
- `adopt-existing`: starts at `/landing`, followed by `/auditphase`.

The base project template is the `new-project` profile. Adoption tools apply the `adopt-existing` profile only when a project does not already have pipeline state. Existing state is never silently overwritten.
