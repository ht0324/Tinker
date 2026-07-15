<p align="center">
  <img src="Sources/TinkerBar/Resources/AppIcon.png" alt="TinkerBar app icon" width="120" height="120">
</p>

# TinkerBar

TinkerBar is a small macOS menu bar app for personal automations that are too useful to forget, but too small to deserve a whole app of their own.

It watches a folder of task definitions, shows their status in the menu bar, and runs each task's `run.sh` on a schedule, when files appear in a watched folder, or when a configured app opens or quits. The app handles the menu, triggers, launch-at-login, status refreshes, and log shortcuts; each worker stays as a plain shell script that is easy to read, replace, or delete.

## Highlights

- Menu bar controls for turning tasks on or off, running them manually, and opening their folders or logs.
- Folder-triggered tasks for workflows like converting new camera files.
- Interval-triggered tasks for recurring maintenance jobs.
- Application-triggered tasks for reacting to app launches and quits.
- File-based task folders, so custom automations are easy to inspect and move around.
- Quiet overnight behavior for automatic runs, while manual runs still work when you ask for them.
- No third-party watcher daemon or long-running shell script hidden in the background.

## Built-In Tasks

TinkerBar currently ships with four example tasks:

- `heic-to-jpeg`: converts new HEIC or HEIF files in a watched folder to JPEG.
- `codex-update`: periodically updates the global Codex CLI with npm.
- `codex-usage-ledger`: records estimated Standard-tier API-equivalent Codex cost into a local ledger and summary file. Remote hosts are optional and configured outside the repo.
- `parsec-macmini-mirror`: mirrors local Parsec launch and quit events to a configured Mac mini.

Each built-in task is installed into the same task-folder format that custom tasks use.

## Getting Started

Clone the repo, then run the app from the project root:

```bash
swift run
```

To build a standalone app bundle:

```bash
./scripts/build-app.sh
open dist/TinkerBar.app
```

The build command uses the repo's strict release settings, removes macOS
metadata that interferes with signing, then ad-hoc signs the local bundle and
strictly verifies a clean restaging of the published artifact. To build, safely
replace the copy in `~/Applications`, relaunch it, and verify the running
executable in one command:

```bash
./scripts/build-app.sh --install
```

Set `TINKERBAR_INSTALL_DIR` if you intentionally use a different local install
directory. This is a local development signature; distributing the app to
other Macs would additionally require a Developer ID signature and notarization.

From the menu bar, use `Reload Tasks` after editing task files, `Open Tasks Folder` to inspect the live task directory, and `Start at Login` if you want TinkerBar to keep working after you restart your Mac.

## Task Folders

Runtime task data lives outside the repo:

```text
~/Library/Application Support/TinkerBar/tasks/
  heic-to-jpeg/
    task.json
    run.sh
    status.tsv
    task.log
  codex-update/
    task.json
    run.sh
    status.tsv
    task.log
  codex-usage-ledger/
    task.json
    run.sh
    codex-usage-app-server.mjs
    ledger.jsonl
    latest-summary.json
    official-usage.json
    status.tsv
    task.log
  parsec-macmini-mirror/
    task.json
    run.sh
    status.tsv
    task.log
```

The app discovers sibling folders under `tasks/`. The task contract is:

- `task.json` describing the task.
- `run.sh` containing the worker script.
- `status.tsv` is created and maintained for the latest run state.
- `task.log` is written or opened on demand for worker output.

## Task Configuration

A folder-triggered task looks like this:

```json
{
  "id": "heic-to-jpeg",
  "name": "HEIC to JPEG",
  "detail": "Convert new HEIC and HEIF files in a folder to JPEG.",
  "scriptKind": "heic_to_jpeg",
  "triggerKind": "directory",
  "directoryPath": "~/Downloads",
  "openPath": "~/Downloads"
}
```

Supported trigger kinds:

- `directory`: runs when new regular files appear in `directoryPath`.
- `interval`: runs every `intervalSeconds`.
- `application`: runs when the configured `applicationName` or
  `bundleIdentifier` opens or quits.

Script argument contracts:

- Directory task: `run.sh <directoryPath> <statusFile> <logFile>`
- Interval task: `run.sh <statusFile> <logFile>`
- Application task: `run.sh <opened|closed|sync> <statusFile> <logFile>`

Worker runs have a 30-minute deadline and can be stopped from the task menu. TinkerBar treats either a nonzero exit status or a nonempty `last_error` status value as a failed run, and records runner-level failures such as timeouts in `status.tsv`.

## Private Task Config

The bundled Codex usage task reads an optional private env file from its runtime task folder:

```text
~/Library/Application Support/TinkerBar/tasks/codex-usage-ledger/config.env
```

Example:

```zsh
TINKERBAR_CODEX_USAGE_REMOTE_HOSTS="workstation server"
TINKERBAR_CODEX_USAGE_TIMEZONE="America/Los_Angeles"
```

Keep that file out of Git. You can also point at another private config path with `TINKERBAR_CODEX_USAGE_CONFIG_FILE`.

### Codex usage estimates

The usage worker runs the unified, pinned `ccusage@20.0.17` collector through `npx` on each configured host. The first run may therefore take longer while npm fetches the pinned package; no global ccusage installation is required. The ccusage process uses its embedded offline pricing data, while `npx` may still contact npm to obtain the pinned package. Standard-tier pricing is fixed explicitly so a host's current Fast or Priority setting cannot retroactively change historical estimates.

The ledger stores the model breakdown returned by ccusage, including current model IDs such as `gpt-5.6-sol`, and marks fallback-attributed or potentially unpriced rows in `latest-summary.json`. A local, best-effort Codex App Server probe also records the current official model catalog and aggregate account activity as a reference. That official data has no per-host or per-model dollar breakdown, so it does not replace the ccusage estimate.

These dollar figures are API-equivalent estimates, not invoices or measured ChatGPT/Codex subscription spend. When the ledger schema or pinned collector version changes, TinkerBar rebuilds the history into temporary files and switches them in only after historical collection succeeds for every configured host and the replacement summary validates. The ledger and summary share a generation ID, so the app suppresses estimates rather than combining mismatched generations after an interrupted switch. The prior ledger and summary receive timestamped `.bak` copies after a successful migration; a failed migration leaves the originals untouched.

## Development

TinkerBar is a SwiftPM macOS app. Source lives in `Sources/TinkerBar/`, bundled worker scripts live in `Sources/TinkerBar/Resources/BuiltinTasks/`, and the bundle builder lives at `scripts/build-app.sh`.

Useful commands:

```bash
swift build
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift run
./scripts/build-app.sh
./scripts/build-app.sh --install
```

For behavior changes, build the app, launch it, and exercise the affected task from the menu bar. For task-format changes, verify the relevant directory, interval, or application task argument contract.
