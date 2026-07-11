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

struct TaskRunner: @unchecked Sendable {
    typealias CommandExecutor = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> CommandResult

    private let fileManager: FileManager
    private let commandExecutor: CommandExecutor
    private let executionTimeout: TimeInterval

    init(
        fileManager: FileManager = .default,
        executionTimeout: TimeInterval = 30 * 60,
        commandExecutor: @escaping CommandExecutor = { executable, arguments, timeout in
            CommandRunner.run(
                executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.fileManager = fileManager
        self.executionTimeout = executionTimeout
        self.commandExecutor = commandExecutor
    }

    func run(_ task: AutomationTaskState, event: ApplicationTriggerEvent? = nil) -> TaskRunOutcome {
        if Task.isCancelled {
            let message = "\(task.configuration.name) stopped before completion."
            return .cancelled(
                persistRunnerError(
                    message,
                    for: task,
                    current: TaskStatusStore.snapshot(for: task.paths, fileManager: fileManager)
                )
            )
        }

        do {
            guard fileManager.fileExists(atPath: task.paths.scriptFile.path) else {
                throw AutomationError.invalidConfiguration(
                    "\(task.configuration.name) needs a run.sh script in \(task.paths.taskDirectory.path)."
                )
            }

            let startingSnapshot = TaskStatusStore.snapshot(for: task.paths, fileManager: fileManager)
            let result = commandExecutor(
                "/bin/zsh",
                try workerArguments(for: task, event: event),
                executionTimeout
            )
            let snapshot = TaskStatusStore.snapshot(for: task.paths, fileManager: fileManager)
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
                persistRunnerError(
                    message,
                    for: task,
                    current: TaskStatusStore.snapshot(for: task.paths, fileManager: fileManager)
                )
            )
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
                persistRunnerError(
                    message,
                    for: task,
                    current: snapshot
                )
            )
        case .timedOut:
            let message = "\(task.configuration.name) timed out after \(formattedTimeout)."
            return .timedOut(
                message,
                persistRunnerError(
                    message,
                    for: task,
                    current: snapshot
                )
            )
        case .completed:
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
                    persistRunnerError(
                        message,
                        for: task,
                        current: snapshot
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

    private func persistRunnerError(
        _ message: String,
        for task: AutomationTaskState,
        current snapshot: AutomationTaskSnapshot
    ) -> AutomationTaskSnapshot {
        TaskStatusStore.recordingRunnerError(
            message,
            in: snapshot,
            for: task.paths,
            fileManager: fileManager
        )
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

}
