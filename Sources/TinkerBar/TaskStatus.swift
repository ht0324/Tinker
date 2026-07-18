import Foundation

enum TaskStatusStore {
    static func createFileIfNeeded(
        for paths: AutomationTaskPaths,
        fileManager: FileManager = .default
    ) throws {
        guard !fileManager.fileExists(atPath: paths.statusFile.path) else { return }
        try Document.empty.contents.write(to: paths.statusFile, atomically: true, encoding: .utf8)
    }

    static func snapshot(
        for paths: AutomationTaskPaths,
        fileManager: FileManager = .default
    ) -> AutomationTaskSnapshot {
        var snapshot = document(at: paths.statusFile).applying(to: AutomationTaskSnapshot())
        snapshot.filesInstalled = fileManager.fileExists(atPath: paths.scriptFile.path)
            && fileManager.fileExists(atPath: paths.statusFile.path)

        if fileManager.fileExists(atPath: paths.summaryFile.path) {
            snapshot.codexUsage = CodexUsageSnapshot.load(
                summaryFile: paths.summaryFile,
                ledgerFile: paths.ledgerFile
            )
        }

        return snapshot
    }

    static func recordingRunnerError(
        _ message: String,
        in snapshot: AutomationTaskSnapshot,
        for paths: AutomationTaskPaths,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) -> AutomationTaskSnapshot {
        var document = document(at: paths.statusFile)
        let sanitizedMessage = sanitizedStatusValue(message)
        document.set(ISO8601DateFormatter().string(from: date), for: .lastRun)
        document.set(sanitizedMessage, for: .lastError)
        document.ensureRequiredEntries()

        do {
            try document.contents.write(to: paths.statusFile, atomically: true, encoding: .utf8)
            return self.snapshot(for: paths, fileManager: fileManager)
        } catch {
            var fallback = snapshot
            fallback.lastError = sanitizedMessage
            return fallback
        }
    }

    private static func document(at url: URL) -> Document {
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Document(contents: contents)
    }

    static func sanitizedStatusValue(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(512))
    }

    private enum Key: String, CaseIterable {
        case lastRun = "last_run_iso"
        case lastSuccess = "last_success_iso"
        case successCount = "success_count"
        case lastOutput = "last_output"
        case lastError = "last_error"

        var defaultValue: String {
            self == .successCount ? "0" : ""
        }
    }

    private struct Entry {
        let key: String
        var value: String
    }

    private struct Document {
        var entries: [Entry]

        static let empty = Document(
            entries: Key.allCases.map { Entry(key: $0.rawValue, value: $0.defaultValue) }
        )

        init(entries: [Entry]) {
            self.entries = entries
        }

        init(contents: String) {
            entries = contents.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first, !key.isEmpty else { return nil }
                return Entry(
                    key: String(key),
                    value: parts.count > 1 ? String(parts[1]) : ""
                )
            }
        }

        var contents: String {
            entries.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n") + "\n"
        }

        mutating func ensureRequiredEntries() {
            for key in Key.allCases where !entries.contains(where: { $0.key == key.rawValue }) {
                entries.append(Entry(key: key.rawValue, value: key.defaultValue))
            }
        }

        mutating func set(_ value: String, for key: Key) {
            let matchingIndices = entries.indices.filter { entries[$0].key == key.rawValue }
            for index in matchingIndices {
                entries[index].value = value
            }

            if matchingIndices.isEmpty {
                entries.append(Entry(key: key.rawValue, value: value))
            }
        }

        func applying(to current: AutomationTaskSnapshot) -> AutomationTaskSnapshot {
            var snapshot = current
            for entry in entries {
                switch Key(rawValue: entry.key) {
                case .lastRun:
                    snapshot.lastRunISO = entry.value
                case .lastSuccess:
                    snapshot.lastSuccessISO = entry.value
                case .successCount:
                    break
                case .lastOutput:
                    snapshot.lastOutput = entry.value
                case .lastError:
                    snapshot.lastError = entry.value
                case nil:
                    break
                }
            }
            return snapshot
        }
    }
}
