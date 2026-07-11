import Foundation

enum TaskRunOutcome: Sendable {
    case success(AutomationTaskSnapshot)
    case failure(String, AutomationTaskSnapshot)
    case timedOut(String, AutomationTaskSnapshot)
    case cancelled(AutomationTaskSnapshot)

    var snapshot: AutomationTaskSnapshot {
        switch self {
        case .success(let snapshot),
             .failure(_, let snapshot),
             .timedOut(_, let snapshot),
             .cancelled(let snapshot):
            return snapshot
        }
    }

    var allowsCoalescedFollowUp: Bool {
        switch self {
        case .success, .failure:
            return true
        case .timedOut, .cancelled:
            return false
        }
    }
}

final class TaskRunner: @unchecked Sendable {
    typealias CommandExecutor = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ cancellation: CommandCancellationToken
    ) -> CommandResult

    typealias SnapshotLoader = @Sendable (AutomationTaskPaths) -> AutomationTaskSnapshot

    private let fileManager: FileManager
    private let commandExecutor: CommandExecutor
    private let executionTimeout: TimeInterval
    private let snapshotLoader: SnapshotLoader
    private let activeExecutionsLock = NSLock()
    private var activeExecutions: [String: CommandCancellationToken] = [:]

    init(
        fileManager: FileManager = .default,
        executionTimeout: TimeInterval = 30 * 60,
        snapshotLoader: @escaping SnapshotLoader = { paths in
            TaskSnapshotLoader().snapshot(for: paths)
        },
        commandExecutor: @escaping CommandExecutor = { executable, arguments, timeout, cancellation in
            CommandRunner.run(
                executable,
                arguments: arguments,
                timeout: timeout,
                cancellation: cancellation
            )
        }
    ) {
        self.fileManager = fileManager
        self.executionTimeout = executionTimeout
        self.snapshotLoader = snapshotLoader
        self.commandExecutor = commandExecutor
    }

    func run(_ task: AutomationTaskState, event: ApplicationTriggerEvent? = nil) -> TaskRunOutcome {
        let cancellation = CommandCancellationToken()
        guard register(cancellation, taskID: task.id) else {
            return .failure(
                "\(task.configuration.name) is already running.",
                snapshotLoader(task.paths)
            )
        }
        defer { unregister(cancellation, taskID: task.id) }

        if Task.isCancelled {
            cancellation.cancel()
            let message = "\(task.configuration.name) stopped before completion."
            return .cancelled(
                snapshotPersistingRunnerError(
                    message,
                    for: task,
                    current: snapshotLoader(task.paths),
                    overwriteExistingError: true
                )
            )
        }

        do {
            guard fileManager.fileExists(atPath: task.paths.scriptFile.path) else {
                throw AutomationError.invalidConfiguration(
                    "\(task.configuration.name) needs a run.sh script in \(task.paths.taskDirectory.path)."
                )
            }

            let startingSnapshot = snapshotLoader(task.paths)
            let result = commandExecutor(
                "/bin/zsh",
                try workerArguments(for: task, event: event),
                executionTimeout,
                cancellation
            )
            let snapshot = snapshotLoader(task.paths)
            return outcome(
                for: task,
                commandResult: result,
                startingSnapshot: startingSnapshot,
                snapshot: snapshot
            )
        } catch {
            let message = error.localizedDescription
            return .failure(
                message,
                snapshotPersistingRunnerError(
                    message,
                    for: task,
                    current: snapshotLoader(task.paths),
                    overwriteExistingError: true
                )
            )
        }
    }

    func cancel(_ taskID: String) {
        activeExecutionsLock.lock()
        let cancellation = activeExecutions[taskID]
        activeExecutionsLock.unlock()
        cancellation?.cancel()
    }

    func cancelAll() {
        activeExecutionsLock.lock()
        let cancellations = Array(activeExecutions.values)
        activeExecutionsLock.unlock()

        for cancellation in cancellations {
            cancellation.cancel()
        }
    }

    func ensureAccess(for task: AutomationTaskState) throws {
        switch task.configuration.triggerKind {
        case .directory:
            let directoryURL = try directoryURL(for: task.configuration)
            _ = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        case .interval:
            break
        case .application:
            guard task.configuration.hasApplicationTarget else {
                throw AutomationError.invalidConfiguration("\(task.configuration.name) needs an applicationName or bundleIdentifier in task.json.")
            }
        }
    }

    private func outcome(
        for task: AutomationTaskState,
        commandResult: CommandResult,
        startingSnapshot: AutomationTaskSnapshot,
        snapshot: AutomationTaskSnapshot
    ) -> TaskRunOutcome {
        switch commandResult.termination {
        case .cancelled:
            let message = "\(task.configuration.name) stopped before completion."
            return .cancelled(
                snapshotPersistingRunnerError(
                    message,
                    for: task,
                    current: snapshot,
                    overwriteExistingError: true
                )
            )
        case .timedOut:
            let message = "\(task.configuration.name) timed out after \(formattedTimeout)."
            return .timedOut(
                message,
                snapshotPersistingRunnerError(
                    message,
                    for: task,
                    current: snapshot,
                    overwriteExistingError: true
                )
            )
        case .launchFailed:
            let message = diagnosticMessage(
                commandResult: commandResult,
                snapshotError: nil,
                fallback: "\(task.configuration.name) could not start."
            )
            return .failure(
                message,
                snapshotPersistingRunnerError(
                    message,
                    for: task,
                    current: snapshot,
                    overwriteExistingError: true
                )
            )
        case .exited:
            if commandResult.exitCode != 0 {
                let currentWorkerError = workerErrorWrittenDuringRun(
                    startingSnapshot: startingSnapshot,
                    snapshot: snapshot
                )
                let message = diagnosticMessage(
                    commandResult: commandResult,
                    snapshotError: currentWorkerError,
                    fallback: "\(task.configuration.name) exited with status \(commandResult.exitCode). Open the task log for details."
                )
                if currentWorkerError != nil {
                    return .failure(message, snapshot)
                }
                return .failure(
                    message,
                    snapshotPersistingRunnerError(
                        message,
                        for: task,
                        current: snapshot,
                        overwriteExistingError: true
                    )
                )
            }

            if let lastError = nonEmpty(snapshot.lastError) {
                return .failure(lastError, snapshot)
            }

            return .success(snapshot)
        }
    }

    private func diagnosticMessage(
        commandResult: CommandResult,
        snapshotError: String?,
        fallback: String
    ) -> String {
        if let snapshotError = nonEmpty(snapshotError ?? "") {
            return snapshotError
        }

        if let stderr = nonEmpty(commandResult.stderr) {
            return sanitizedStatusValue(stderr, maxLength: 512)
        }

        if let stdout = nonEmpty(commandResult.stdout) {
            return sanitizedStatusValue(stdout, maxLength: 512)
        }

        return fallback
    }

    private func workerErrorWrittenDuringRun(
        startingSnapshot: AutomationTaskSnapshot,
        snapshot: AutomationTaskSnapshot
    ) -> String? {
        guard let currentError = nonEmpty(snapshot.lastError) else {
            return nil
        }

        let previousError = nonEmpty(startingSnapshot.lastError)
        guard
            currentError != previousError
                || snapshot.lastRunISO != startingSnapshot.lastRunISO
        else {
            return nil
        }
        return currentError
    }

    private func snapshotPersistingRunnerError(
        _ message: String,
        for task: AutomationTaskState,
        current snapshot: AutomationTaskSnapshot,
        overwriteExistingError: Bool = false
    ) -> AutomationTaskSnapshot {
        if !overwriteExistingError, nonEmpty(snapshot.lastError) != nil {
            return snapshot
        }

        let sanitizedMessage = sanitizedStatusValue(message, maxLength: 512)
        var entries = statusEntries(at: task.paths.statusFile)
        setStatusValue(ISO8601DateFormatter().string(from: Date()), for: "last_run_iso", entries: &entries)
        setStatusValue(sanitizedMessage, for: "last_error", entries: &entries)

        let defaults = [
            StatusEntry(key: "last_success_iso", value: ""),
            StatusEntry(key: "success_count", value: "0"),
            StatusEntry(key: "last_output", value: ""),
        ]
        for entry in defaults where !entries.contains(where: { $0.key == entry.key }) {
            entries.append(entry)
        }

        let statusText = entries
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n") + "\n"

        do {
            try statusText.write(to: task.paths.statusFile, atomically: true, encoding: .utf8)
            return snapshotLoader(task.paths)
        } catch {
            var fallbackSnapshot = snapshot
            fallbackSnapshot.lastError = sanitizedMessage
            return fallbackSnapshot
        }
    }

    private func statusEntries(at url: URL) -> [StatusEntry] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        return contents.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { return nil }
            return StatusEntry(
                key: String(key),
                value: parts.count > 1 ? String(parts[1]) : ""
            )
        }
    }

    private func setStatusValue(_ value: String, for key: String, entries: inout [StatusEntry]) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value = value
        } else {
            entries.append(StatusEntry(key: key, value: value))
        }
    }

    private func sanitizedStatusValue(_ value: String, maxLength: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(maxLength))
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var formattedTimeout: String {
        let roundedSeconds = max(Int(executionTimeout.rounded()), 1)
        if roundedSeconds % 60 == 0 {
            let minutes = roundedSeconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }

        return roundedSeconds == 1 ? "1 second" : "\(roundedSeconds) seconds"
    }

    private func register(_ cancellation: CommandCancellationToken, taskID: String) -> Bool {
        activeExecutionsLock.lock()
        defer { activeExecutionsLock.unlock() }

        guard activeExecutions[taskID] == nil else { return false }
        activeExecutions[taskID] = cancellation
        return true
    }

    private func unregister(_ cancellation: CommandCancellationToken, taskID: String) {
        activeExecutionsLock.lock()
        defer { activeExecutionsLock.unlock() }

        guard activeExecutions[taskID] === cancellation else { return }
        activeExecutions[taskID] = nil
    }

    private func workerArguments(for task: AutomationTaskState, event: ApplicationTriggerEvent?) throws -> [String] {
        switch task.configuration.triggerKind {
        case .directory:
            let directoryURL = try directoryURL(for: task.configuration)
            return [
                task.paths.scriptFile.path,
                directoryURL.path,
                task.paths.statusFile.path,
                task.paths.logFile.path,
            ]
        case .interval:
            return [
                task.paths.scriptFile.path,
                task.paths.statusFile.path,
                task.paths.logFile.path,
            ]
        case .application:
            return [
                task.paths.scriptFile.path,
                (event ?? .sync).rawValue,
                task.paths.statusFile.path,
                task.paths.logFile.path,
            ]
        }
    }

    private func directoryURL(for configuration: AutomationTaskConfiguration) throws -> URL {
        guard let directoryURL = configuration.resolvedDirectoryURL else {
            throw AutomationError.invalidConfiguration("\(configuration.name) needs a directoryPath in task.json.")
        }

        return directoryURL
    }

    private struct StatusEntry {
        let key: String
        var value: String
    }
}
