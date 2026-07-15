# Repository Guidelines

## Project Structure & Module Organization
`TinkerBar` is a SwiftPM macOS menu bar app. Source lives in `Sources/TinkerBar/`. Key files include `TinkerBarApp.swift` for app entry, `ContentView.swift` for the menu UI, `AutomationRuntime.swift` for live task lifecycle state, and `TaskCatalog.swift`, `TaskRunner.swift`, `TaskOpener.swift`, plus `DirectoryMonitor.swift` for task discovery, execution, opening, and folder events. Build and local-install behavior lives in `scripts/build-app.sh`. Runtime task data is not stored in the repo: the app reads sibling task folders from `~/Library/Application Support/TinkerBar/tasks/<task-id>/`, each containing `task.json`, `run.sh`, `status.tsv`, and `task.log`.

## Build, Test, and Development Commands
Run from the repo root:

- `swift run` starts the menu bar app in development mode.
- `swift build` compiles the executable target and is the fastest sanity check before opening a PR.
- `./scripts/build-app.sh` creates and ad-hoc signs `dist/TinkerBar.app` with strict release settings, then verifies a clean restaging of the published artifact.
- `./scripts/build-app.sh --install` also stages the bundle into `~/Applications`, relaunches it, and verifies the live executable path.
- `open dist/TinkerBar.app` launches the built app bundle for manual verification.
- `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` runs the committed regression suite under the strict compiler settings used for release verification.

## Coding Style & Naming Conventions
Follow existing Swift style: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties and methods, and focused files with one main type per file when practical. Keep SwiftUI state in the model/controller layer instead of embedding task logic in views. Match existing task naming: folder IDs such as `heic-to-jpeg` are kebab-case, while JSON keys stay descriptive and explicit, for example `triggerKind` and `directoryPath`.

## Testing Guidelines
Add focused XCTest coverage for behavior changes, then run the strict full suite. Launch the app and exercise user-visible flows through the menu bar when the change warrants manual verification. For task-format changes, confirm the task contract still holds: directory tasks receive `run.sh <directoryPath> <statusFile> <logFile>`, interval tasks receive `run.sh <statusFile> <logFile>`, and application tasks receive `run.sh <opened|closed|sync> <statusFile> <logFile>`.

## Commit & Pull Request Guidelines
Current history uses short, imperative commit subjects such as `Build multi-task TinkerBar app`. Keep commits focused and descriptive. PRs should explain the user-visible change, note any task-folder or config contract changes, and include screenshots for menu/UI updates. If you changed task behavior, mention the exact manual verification steps you ran.
