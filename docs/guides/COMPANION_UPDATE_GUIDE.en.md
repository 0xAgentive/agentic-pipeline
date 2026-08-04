# Updating Pipeline 1.2.6, Runtime 1.2.3 and Companion 1.2.4

1. Update the local repository and GitHub with the release-kit script.
2. Replace ChatGPT Project Instructions with `01_PROJECT_INSTRUCTIONS_v1.2.4.md`.
3. Keep one active copy of each `knowledge/00–15` module.
4. Remove active Companion 1.2.3 and older modules.
5. After the active product work item closes, run `Update-AgenticProjectRuntime-v1.2.3.ps1` in dry-run and then with `-Apply`.

The runtime updater changes only an explicit framework-owned allowlist and preserves product source, project documentation, work-item results and project-owned state.
