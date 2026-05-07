import Foundation

struct TaskCatalog {
    private let fileManager: FileManager
    private let builtInTasks: BuiltinTaskInstaller
    private let snapshotLoader: TaskSnapshotLoader
    private let installsBuiltInTasks: Bool

    let appSupportDirectory: URL
    let tasksDirectory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        builtInTasks: BuiltinTaskInstaller = BuiltinTaskInstaller(),
        snapshotLoader: TaskSnapshotLoader = TaskSnapshotLoader(),
        installsBuiltInTasks: Bool = true
    ) {
        self.init(
            appSupportDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("TinkerBar", isDirectory: true),
            fileManager: fileManager,
            builtInTasks: builtInTasks,
            snapshotLoader: snapshotLoader,
            installsBuiltInTasks: installsBuiltInTasks
        )
    }

    init(
        appSupportDirectory: URL,
        fileManager: FileManager = .default,
        builtInTasks: BuiltinTaskInstaller = BuiltinTaskInstaller(),
        snapshotLoader: TaskSnapshotLoader = TaskSnapshotLoader(),
        installsBuiltInTasks: Bool = true
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.tasksDirectory = appSupportDirectory.appendingPathComponent("tasks", isDirectory: true)
        self.fileManager = fileManager
        self.builtInTasks = builtInTasks
        self.snapshotLoader = snapshotLoader
        self.installsBuiltInTasks = installsBuiltInTasks
    }

    func discoverTasks() throws -> [AutomationTaskState] {
        try fileManager.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

        if installsBuiltInTasks {
            try builtInTasks.installDefaultTasksIfNeeded(tasksDirectory: tasksDirectory)
        }

        let folderURLs = try fileManager.contentsOfDirectory(
            at: tasksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var tasks: [AutomationTaskState] = []

        for folderURL in folderURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let resourceValues = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else { continue }

            let paths = AutomationTaskPaths(taskDirectory: folderURL)
            guard fileManager.fileExists(atPath: paths.configFile.path) else { continue }

            let configData = try Data(contentsOf: paths.configFile)
            let configuration = try JSONDecoder().decode(AutomationTaskConfiguration.self, from: configData)
            try builtInTasks.ensureSupportFiles(for: configuration, paths: paths)

            tasks.append(
                AutomationTaskState(
                    configuration: configuration,
                    paths: paths,
                    snapshot: snapshot(for: paths),
                    isEnabled: false,
                    isRunning: false
                )
            )
        }

        return tasks.sorted { lhs, rhs in
            let leftPriority = taskSortPriority(lhs.configuration.id)
            let rightPriority = taskSortPriority(rhs.configuration.id)
            guard leftPriority == rightPriority else { return leftPriority < rightPriority }
            return lhs.configuration.name.localizedCaseInsensitiveCompare(rhs.configuration.name) == .orderedAscending
        }
    }

    func snapshot(for paths: AutomationTaskPaths) -> AutomationTaskSnapshot {
        snapshotLoader.snapshot(for: paths)
    }

    private func taskSortPriority(_ taskID: String) -> Int {
        switch taskID {
        case "codex-usage-ledger":
            return 0
        case "codex-update":
            return 1
        default:
            return 2
        }
    }
}
