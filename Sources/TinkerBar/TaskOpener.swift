import AppKit
import Foundation

struct TaskOpener {
    typealias OpenHandler = (URL) -> Void

    private let fileManager: FileManager
    private let openHandler: OpenHandler
    private let tasksDirectory: URL

    init(
        tasksDirectory: URL,
        fileManager: FileManager = .default,
        openHandler: @escaping OpenHandler = { NSWorkspace.shared.open($0) }
    ) {
        self.tasksDirectory = tasksDirectory
        self.fileManager = fileManager
        self.openHandler = openHandler
    }

    func openTasksDirectory() {
        openHandler(tasksDirectory)
    }

    func openTaskFolder(_ task: AutomationTaskState) {
        openHandler(task.paths.taskDirectory)
    }

    func openTaskLog(_ task: AutomationTaskState) {
        if !fileManager.fileExists(atPath: task.paths.logFile.path) {
            fileManager.createFile(atPath: task.paths.logFile.path, contents: Data())
        }

        openHandler(task.paths.logFile)
    }

    func openTaskTarget(_ task: AutomationTaskState) {
        if let openURL = task.configuration.resolvedOpenURL {
            openHandler(openURL)
            return
        }

        if let directoryURL = task.configuration.resolvedDirectoryURL {
            openHandler(directoryURL)
            return
        }

        openHandler(task.paths.taskDirectory)
    }
}
