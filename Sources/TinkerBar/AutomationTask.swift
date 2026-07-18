import Foundation

enum AutomationTriggerKind: String, Codable, Sendable {
    case directory
    case interval
    case application
}

enum ApplicationTriggerEvent: String, Sendable {
    case opened
    case closed
    case sync
}

struct AutomationTaskConfiguration: Codable, Sendable {
    var id: String
    var name: String
    var detail: String
    var scriptKind: String?
    var triggerKind: AutomationTriggerKind
    var directoryPath: String?
    var intervalSeconds: Double?
    var openPath: String?
    var applicationName: String? = nil
    var bundleIdentifier: String? = nil

    var resolvedDirectoryURL: URL? {
        guard let directoryPath, !directoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: directoryPath.expandingTildeInPath, isDirectory: true)
    }

    var resolvedOpenURL: URL? {
        guard let openPath, !openPath.isEmpty else { return nil }
        return URL(fileURLWithPath: openPath.expandingTildeInPath, isDirectory: true)
    }

    var applicationTargetDescription: String? {
        if let applicationName, !applicationName.isEmpty {
            return applicationName
        }

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    var hasApplicationTarget: Bool {
        applicationTargetDescription != nil
    }

    var triggerDescription: String {
        switch triggerKind {
        case .directory:
            return "Folder trigger"
        case .interval:
            return "Scheduled"
        case .application:
            return "Application trigger"
        }
    }

    var triggerDetail: String {
        switch triggerKind {
        case .directory:
            return directoryPath ?? "No folder configured"
        case .interval:
            guard let intervalSeconds, intervalSeconds > 0 else {
                return "No interval configured"
            }
            return "Every \(formatInterval(intervalSeconds))"
        case .application:
            return applicationTargetDescription ?? "No app configured"
        }
    }
}

struct AutomationTaskPaths: Sendable {
    let taskDirectory: URL

    var configFile: URL {
        taskDirectory.appendingPathComponent("task.json")
    }

    var scriptFile: URL {
        taskDirectory.appendingPathComponent("run.sh")
    }

    var statusFile: URL {
        taskDirectory.appendingPathComponent("status.tsv")
    }

    var logFile: URL {
        taskDirectory.appendingPathComponent("task.log")
    }

    var ledgerFile: URL {
        taskDirectory.appendingPathComponent("ledger.jsonl")
    }

    var summaryFile: URL {
        taskDirectory.appendingPathComponent("latest-summary.json")
    }
}

struct AutomationTaskSnapshot: Sendable {
    var filesInstalled = false
    var lastRunISO = ""
    var lastSuccessISO = ""
    var lastOutput = ""
    var lastError = ""
    var codexUsage: CodexUsageSnapshot?
}

struct AutomationTaskState: Identifiable, Sendable {
    var configuration: AutomationTaskConfiguration
    var paths: AutomationTaskPaths
    var snapshot: AutomationTaskSnapshot
    var isEnabled: Bool
    var isRunning: Bool

    var id: String {
        configuration.id
    }
}

private func formatInterval(_ seconds: Double) -> String {
    let roundedSeconds = max(Int(seconds.rounded()), 1)

    if roundedSeconds % 3600 == 0 {
        let hours = roundedSeconds / 3600
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    if roundedSeconds % 60 == 0 {
        let minutes = roundedSeconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    return roundedSeconds == 1 ? "1 second" : "\(roundedSeconds) seconds"
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
