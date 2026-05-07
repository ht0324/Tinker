import Foundation

struct TaskSnapshotLoader {
    private let fileManager = FileManager.default

    func snapshot(for paths: AutomationTaskPaths) -> AutomationTaskSnapshot {
        var snapshot = AutomationTaskSnapshot()
        snapshot.filesInstalled = fileManager.fileExists(atPath: paths.scriptFile.path)
            && fileManager.fileExists(atPath: paths.statusFile.path)

        if let statusText = try? String(contentsOf: paths.statusFile, encoding: .utf8) {
            for line in statusText.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]) : ""

                switch key {
                case "last_run_iso":
                    snapshot.lastRunISO = value
                case "last_success_iso":
                    snapshot.lastSuccessISO = value
                case "success_count":
                    snapshot.successCount = Int(value) ?? 0
                case "last_output":
                    snapshot.lastOutput = value
                case "last_error":
                    snapshot.lastError = value
                default:
                    break
                }
            }
        }

        snapshot.codexUsage = CodexUsageSnapshot.load(summaryFile: paths.summaryFile, ledgerFile: paths.ledgerFile)
        return snapshot
    }
}
