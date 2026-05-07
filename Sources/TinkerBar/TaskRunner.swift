import Foundation

struct TaskRunner: @unchecked Sendable {
    typealias CommandExecutor = @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult

    private let fileManager: FileManager
    private let builtInTasks: BuiltinTaskInstaller
    private let commandExecutor: CommandExecutor

    init(
        fileManager: FileManager = .default,
        builtInTasks: BuiltinTaskInstaller = BuiltinTaskInstaller(),
        commandExecutor: @escaping CommandExecutor = { executable, arguments in
            CommandRunner.run(executable, arguments: arguments)
        }
    ) {
        self.fileManager = fileManager
        self.builtInTasks = builtInTasks
        self.commandExecutor = commandExecutor
    }

    func run(_ task: AutomationTaskState) throws {
        try builtInTasks.ensureSupportFiles(for: task.configuration, paths: task.paths)

        let result = commandExecutor("/bin/zsh", try workerArguments(for: task))
        guard result.exitCode == 0 else {
            throw AutomationError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func ensureAccess(for task: AutomationTaskState) throws {
        switch task.configuration.triggerKind {
        case .directory:
            let directoryURL = try directoryURL(for: task.configuration)
            _ = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        case .interval:
            break
        }
    }

    private func workerArguments(for task: AutomationTaskState) throws -> [String] {
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
        }
    }

    private func directoryURL(for configuration: AutomationTaskConfiguration) throws -> URL {
        guard let directoryURL = configuration.resolvedDirectoryURL else {
            throw AutomationError.invalidConfiguration("\(configuration.name) needs a directoryPath in task.json.")
        }

        return directoryURL
    }
}
