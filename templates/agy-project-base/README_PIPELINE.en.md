# How to use this template

This folder contains the base Antigravity project template files for the Agentic Development Pipeline.

## Workspace Lifecycle

For any project workspace using this pipeline, execute workflows in this sequence:

1.  **Requirement Specification**:
    ```text
    /specdoc
    ```
2.  **Implementation Planning**:
    ```text
    /planonly
    ```
3.  **Local Workspace Verification**:
    ```text
    /auditphase
    ```
4.  **Incremental Implementation**:
    ```text
    /nextphase
    ```
    *(Always implement exactly one phase, verify it, commit/checkpoint, and stop.)*
5.  **Final Verification & Shipping**:
    ```text
    /shipcheck
    ```

## Crucial Rule

Do not skip phases. LLM chat reports are not verification. Trust only deterministic commands, tests, diffs, and logs in the local environment.

For detailed documentation, refer to the root [README.md](../../README.md) of the agentic-pipeline repository.
