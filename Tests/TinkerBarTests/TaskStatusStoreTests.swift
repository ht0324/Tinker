import Foundation
import XCTest
@testable import TinkerBar

final class TaskStatusStoreTests: XCTestCase {
    func testCreatesCanonicalFileWithoutOverwritingExistingStatus() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try TaskStatusStore.createFileIfNeeded(for: fixture.paths)
        XCTAssertEqual(
            try String(contentsOf: fixture.paths.statusFile, encoding: .utf8),
            "last_run_iso\t\nlast_success_iso\t\nsuccess_count\t0\nlast_output\t\nlast_error\t\n"
        )

        try "custom_key\tkeep\n".write(to: fixture.paths.statusFile, atomically: true, encoding: .utf8)
        try TaskStatusStore.createFileIfNeeded(for: fixture.paths)
        XCTAssertEqual(
            try String(contentsOf: fixture.paths.statusFile, encoding: .utf8),
            "custom_key\tkeep\n"
        )
    }

    func testLoadsKnownFieldsAndRequiresBothSupportFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try """
        last_run_iso\t2026-07-10T12:00:00Z
        last_success_iso\t2026-07-10T11:00:00Z
        success_count\tnot-a-number
        last_output\tvalue\twith\ttabs
        last_error\tworker failed
        unknown\tignored

        """.write(to: fixture.paths.statusFile, atomically: true, encoding: .utf8)

        var snapshot = TaskStatusStore.snapshot(for: fixture.paths)
        XCTAssertFalse(snapshot.filesInstalled)
        XCTAssertEqual(snapshot.lastRunISO, "2026-07-10T12:00:00Z")
        XCTAssertEqual(snapshot.lastSuccessISO, "2026-07-10T11:00:00Z")
        XCTAssertEqual(snapshot.successCount, 0)
        XCTAssertEqual(snapshot.lastOutput, "value\twith\ttabs")
        XCTAssertEqual(snapshot.lastError, "worker failed")

        try "#!/bin/zsh\nexit 0\n".write(to: fixture.paths.scriptFile, atomically: true, encoding: .utf8)
        snapshot = TaskStatusStore.snapshot(for: fixture.paths)
        XCTAssertTrue(snapshot.filesInstalled)
    }

    func testRunnerErrorUpdatePreservesUnknownRowsAndUpdatesDuplicates() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try "#!/bin/zsh\n".write(to: fixture.paths.scriptFile, atomically: true, encoding: .utf8)
        try """
        last_run_iso\told-run
        custom_key\tkeep\tall\ttabs
        last_error\told-one
        last_error\told-two

        """.write(to: fixture.paths.statusFile, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 0)
        let message = "bad\tline\n" + String(repeating: "x", count: 600)

        let snapshot = TaskStatusStore.recordingRunnerError(
            message,
            in: AutomationTaskSnapshot(),
            for: fixture.paths,
            date: date
        )
        let persisted = try String(contentsOf: fixture.paths.statusFile, encoding: .utf8)
        let errorRows = persisted.split(separator: "\n").filter { $0.hasPrefix("last_error\t") }

        XCTAssertEqual(snapshot.lastRunISO, "1970-01-01T00:00:00Z")
        XCTAssertEqual(snapshot.lastError.count, 512)
        XCTAssertFalse(snapshot.lastError.contains("\t"))
        XCTAssertFalse(snapshot.lastError.contains("\n"))
        XCTAssertTrue(snapshot.filesInstalled)
        XCTAssertEqual(errorRows.count, 2)
        XCTAssertTrue(errorRows.allSatisfy { $0 == "last_error\t\(snapshot.lastError)" })
        XCTAssertTrue(persisted.contains("custom_key\tkeep\tall\ttabs"))
        XCTAssertTrue(persisted.contains("last_success_iso\t\n"))
        XCTAssertTrue(persisted.contains("success_count\t0\n"))
        XCTAssertTrue(persisted.contains("last_output\t\n"))
    }

    func testRunnerErrorWriteFailureReturnsCurrentSnapshotWithSanitizedError() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.paths.statusFile, withIntermediateDirectories: false)

        var current = AutomationTaskSnapshot()
        current.lastRunISO = "keep-run"
        current.lastSuccessISO = "keep-success"
        current.successCount = 9
        current.lastOutput = "keep-output"

        let snapshot = TaskStatusStore.recordingRunnerError(
            "new\terror\nmessage",
            in: current,
            for: fixture.paths
        )

        XCTAssertEqual(snapshot.lastRunISO, "keep-run")
        XCTAssertEqual(snapshot.lastSuccessISO, "keep-success")
        XCTAssertEqual(snapshot.successCount, 9)
        XCTAssertEqual(snapshot.lastOutput, "keep-output")
        XCTAssertEqual(snapshot.lastError, "new error message")
    }

    func testRunnerErrorRecreatesMissingStatusAndReturnsAuthoritativeSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "#!/bin/zsh\n".write(to: fixture.paths.scriptFile, atomically: true, encoding: .utf8)

        let snapshot = TaskStatusStore.recordingRunnerError(
            "worker failed",
            in: AutomationTaskSnapshot(),
            for: fixture.paths,
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.statusFile.path))
        XCTAssertTrue(snapshot.filesInstalled)
        XCTAssertEqual(snapshot.lastRunISO, "1970-01-01T00:00:00Z")
        XCTAssertEqual(snapshot.lastError, "worker failed")
    }

    private func makeFixture() throws -> (root: URL, paths: AutomationTaskPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskStatusStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, AutomationTaskPaths(taskDirectory: root))
    }
}
