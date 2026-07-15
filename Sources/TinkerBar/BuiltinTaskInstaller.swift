import Foundation

struct BuiltinTaskInstaller {
    private static let codexUsageAppServerHelperFileName = "codex-usage-app-server.mjs"
    private let fileManager = FileManager.default

    func installDefaultTasksIfNeeded(tasksDirectory: URL) throws {
        for configuration in defaultTaskConfigurations {
            let paths = AutomationTaskPaths(taskDirectory: tasksDirectory.appendingPathComponent(configuration.id, isDirectory: true))
            try fileManager.createDirectory(at: paths.taskDirectory, withIntermediateDirectories: true)

            if !fileManager.fileExists(atPath: paths.configFile.path) {
                try writeConfiguration(configuration, to: paths.configFile)
            } else {
                try migrateConfigurationIfNeeded(defaultConfiguration: configuration, paths: paths)
            }

            try ensureSupportFiles(for: configuration, paths: paths)
        }
    }

    func ensureSupportFiles(for configuration: AutomationTaskConfiguration, paths: AutomationTaskPaths) throws {
        try fileManager.createDirectory(at: paths.taskDirectory, withIntermediateDirectories: true)

        if let contents = try builtinScriptContents(for: configuration) {
            try writeIfChanged(contents: contents, to: paths.scriptFile)
        } else if !fileManager.fileExists(atPath: paths.scriptFile.path) {
            throw AutomationError.invalidConfiguration("\(configuration.name) needs a run.sh script in \(paths.taskDirectory.path).")
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.scriptFile.path)

        if configuration.id == "codex-usage-ledger" {
            guard let helperURL = Bundle.module.url(
                forResource: "codex_usage_app_server",
                withExtension: "mjs"
            ) else {
                throw AutomationError.invalidConfiguration("Missing Codex usage App Server helper.")
            }
            let helperContents = try String(contentsOf: helperURL, encoding: .utf8)
            let helperFile = paths.taskDirectory.appendingPathComponent(
                Self.codexUsageAppServerHelperFileName
            )
            try writeIfChanged(contents: helperContents, to: helperFile)
        }

        try TaskStatusStore.createFileIfNeeded(for: paths, fileManager: fileManager)
    }

    private func migrateConfigurationIfNeeded(
        defaultConfiguration: AutomationTaskConfiguration,
        paths: AutomationTaskPaths
    ) throws {
        guard defaultConfiguration.id == "codex-usage-ledger" else { return }

        guard
            let data = try? Data(contentsOf: paths.configFile),
            var configuration = try? JSONDecoder().decode(AutomationTaskConfiguration.self, from: data)
        else {
            // TaskCatalog will report a malformed folder without preventing
            // the remaining built-in and custom tasks from loading.
            return
        }
        guard configuration.id == defaultConfiguration.id else { return }

        var changed = false
        let oldDetailPrefix = "Track Codex spend"
        let detailSuffix = configuration.detail.dropFirst(
            min(oldDetailPrefix.count, configuration.detail.count)
        )
        if configuration.detail.hasPrefix(oldDetailPrefix),
           detailSuffix.isEmpty || detailSuffix.first?.isWhitespace == true {
            configuration.detail = "Track estimated Codex API-equivalent cost"
                + detailSuffix
            changed = true
        }

        if configuration.scriptKind == nil {
            configuration.scriptKind = defaultConfiguration.scriptKind
            changed = true
        }

        if changed {
            try writeConfiguration(configuration, to: paths.configFile)
        }
    }

    private func builtinScriptContents(for configuration: AutomationTaskConfiguration) throws -> String? {
        guard let scriptKind = configuration.scriptKind else { return nil }
        guard let scriptURL = Bundle.module.url(forResource: scriptKind, withExtension: "sh") else {
            throw AutomationError.invalidConfiguration("Missing bundled script for \(configuration.name).")
        }

        return try String(contentsOf: scriptURL, encoding: .utf8)
    }

    private func writeConfiguration(_ configuration: AutomationTaskConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url)
    }

    private func writeIfChanged(contents: String, to url: URL) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != contents else { return }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private var defaultTaskConfigurations: [AutomationTaskConfiguration] {
        [
            AutomationTaskConfiguration(
                id: "heic-to-jpeg",
                name: "HEIC to JPEG",
                detail: "Convert new HEIC and HEIF files in a folder to JPEG.",
                scriptKind: "heic_to_jpeg",
                triggerKind: .directory,
                directoryPath: "~/Downloads",
                intervalSeconds: nil,
                openPath: "~/Downloads"
            ),
            AutomationTaskConfiguration(
                id: "codex-update",
                name: "Codex Update",
                detail: "Keep the global Codex CLI current with npm.",
                scriptKind: "codex_update",
                triggerKind: .interval,
                directoryPath: nil,
                intervalSeconds: 21600,
                openPath: nil
            ),
            AutomationTaskConfiguration(
                id: "codex-usage-ledger",
                name: "Codex Usage Ledger",
                detail: "Track estimated Codex API-equivalent cost for this Mac and any configured remote hosts.",
                scriptKind: "codex_usage_ledger",
                triggerKind: .interval,
                directoryPath: nil,
                intervalSeconds: 1800,
                openPath: "~/Library/Application Support/TinkerBar/tasks/codex-usage-ledger"
            ),
            AutomationTaskConfiguration(
                id: "parsec-macmini-mirror",
                name: "Parsec Mac Mini Mirror",
                detail: "Mirror local Parsec launch and quit events to the Mac mini.",
                scriptKind: "parsec_macmini_mirror",
                triggerKind: .application,
                directoryPath: nil,
                intervalSeconds: nil,
                openPath: "~/Library/Application Support/TinkerBar/tasks/parsec-macmini-mirror",
                applicationName: "Parsec",
                bundleIdentifier: "tv.parsec.www"
            ),
        ]
    }
}
