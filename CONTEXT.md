# TinkerBar Context

## Terms

- **Automation Runtime**: the app-side module that owns live task lifecycle state, including discovered tasks, enabled and running flags, directory monitors, interval loops, debounced runs, and snapshot refreshes. It does not own the worker script implementation; scripts remain task-folder workers.
- **Task Catalog**: the app-side module that prepares the task folder directory, installs or refreshes built-in task files, discovers sibling task folders, decodes `task.json`, and returns task records for the Automation Runtime.
- **Task Runner**: the app-side module that validates a task can run, owns its worker process lifecycle (bounded output, timeout, cancellation, and process-group cleanup), invokes the task-folder worker script with the current argument contract, and returns the authoritative post-run snapshot and outcome.
- **Task Status**: the app-side module that owns the `status.tsv` schema, default file creation, parsing into task snapshots, preservation of unknown fields, and atomic runner-generated status updates. Task-folder workers remain responsible for publishing their own status values through the same file contract.
- **Codex Usage Snapshot**: the app-side module that decodes and aggregates the versioned Codex usage ledger, owns partial-host, estimator-diagnostic, official-account reference, generation-integrity, and display-formatting rules, and returns presentation-ready totals and host rows to the menu UI. Dollar values are estimated Standard-tier API-equivalent costs, not billed subscription spend.
- **Task Opener**: the app-side module that opens task-related filesystem targets, including the tasks folder, a task folder, a task log, or a task target.
- **Task Enablement Store**: the app-side module that reads and writes per-task enabled state, keyed by task ID in `UserDefaults`.
- **App Bundle Workflow**: the repo-side module that owns strict release compilation, standalone bundle assembly, signing-metadata cleanup, local ad-hoc signing, bundle validation, staged installation, relaunch, and live executable verification. It does not provide Developer ID distribution signing or notarization.
