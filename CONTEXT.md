# TinkerBar Context

## Terms

- **Automation Runtime**: the app-side module that owns live task lifecycle state, including discovered tasks, enabled and running flags, directory monitors, interval loops, debounced runs, and snapshot refreshes. It does not own the worker script implementation; scripts remain task-folder workers.
- **Task Catalog**: the app-side module that prepares the task folder directory, installs or refreshes built-in task files, discovers sibling task folders, decodes `task.json`, and returns task records for the Automation Runtime.
- **Task Runner**: the app-side module that validates a task can run and invokes its task-folder worker script with the current argument contract.
- **Task Opener**: the app-side module that opens task-related filesystem targets, including the tasks folder, a task folder, a task log, or a task target.
- **Task Enablement Store**: the app-side module that reads and writes per-task enabled state, keyed by task ID in `UserDefaults`.
