# Repository Guidelines

## Project Structure & Module Organization
`TinkerBar` is a SwiftPM macOS menu bar app. Source lives in `Sources/TinkerBar/`. Key files include `TinkerBarApp.swift` for app entry, `ContentView.swift` for the menu UI, `AutomationRuntime.swift` for live task lifecycle state, and `TaskCatalog.swift`, `TaskRunner.swift`, `TaskOpener.swift`, plus `DirectoryMonitor.swift` for task discovery, execution, opening, and folder events. Build helpers live in `scripts/`, notably `scripts/build-app.sh`. Runtime task data is not stored in the repo: the app reads sibling task folders from `~/Library/Application Support/TinkerBar/tasks/<task-id>/`, each containing `task.json`, `run.sh`, `status.tsv`, and `task.log`.

## Build, Test, and Development Commands
Run from the repo root:

- `swift run` starts the menu bar app in development mode.
- `swift build` compiles the executable target and is the fastest sanity check before opening a PR.
- `./scripts/build-app.sh` creates `dist/TinkerBar.app`.
- `open dist/TinkerBar.app` launches the built app bundle for manual verification.
- `swift test` is the standard test command, but it currently reports `no tests found`; add a `Tests/` target before relying on it in CI.

## Coding Style & Naming Conventions
Follow existing Swift style: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties and methods, and focused files with one main type per file when practical. Keep SwiftUI state in the model/controller layer instead of embedding task logic in views. Match existing task naming: folder IDs such as `heic-to-jpeg` are kebab-case, while JSON keys stay descriptive and explicit, for example `triggerKind` and `directoryPath`.

## Testing Guidelines
There is no committed automated test suite yet. For behavior changes, verify with `swift build`, launch the app, and exercise the affected task flow through the menu bar UI. For task-format changes, confirm the task contract still holds: directory tasks receive `run.sh <directoryPath> <statusFile> <logFile>`, and interval tasks receive `run.sh <statusFile> <logFile>`.

## Commit & Pull Request Guidelines
Current history uses short, imperative commit subjects such as `Build multi-task TinkerBar app`. Keep commits focused and descriptive. PRs should explain the user-visible change, note any task-folder or config contract changes, and include screenshots for menu/UI updates. If you changed task behavior, mention the exact manual verification steps you ran.
