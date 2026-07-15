import Darwin
import Foundation
import XCTest
@testable import TinkerBar

private let staleWorkerStatus = """
last_run_iso\t2026-01-01T00:00:00Z
last_success_iso\t
success_count\t0
last_output\t
last_error\tstale worker failure
"""

final class TaskRunnerReliabilityTests: XCTestCase {
    func testExitZeroWithWorkerErrorReturnsFailure() throws {
        let fixture = try makeTaskFixture(
            status: """
            last_run_iso\t2026-07-10T00:00:00Z
            last_success_iso\t
            success_count\t0
            last_output\t
            last_error\tworker reported failure
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = TaskRunner(commandExecutor: { _, _, _ in
            CommandResult(exitCode: 0, stdout: "", stderr: "")
        })

        guard case .failure(let message, let snapshot) = runner.run(fixture.task) else {
            return XCTFail("Expected worker status error to make the run fail")
        }

        XCTAssertEqual(message, "worker reported failure")
        XCTAssertEqual(snapshot.lastError, "worker reported failure")
    }

    func testNonzeroExitPersistsFallbackDiagnostic() throws {
        let fixture = try makeTaskFixture(
            status: """
            last_run_iso\t
            last_success_iso\t
            success_count\t0
            last_output\t
            last_error\t
            custom_key\tkeep-me
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = TaskRunner(commandExecutor: { _, _, _ in
            CommandResult(exitCode: 7, stdout: "", stderr: "")
        })

        guard case .failure(let message, let snapshot) = runner.run(fixture.task) else {
            return XCTFail("Expected nonzero exit to fail")
        }

        XCTAssertTrue(message.contains("status 7"))
        XCTAssertEqual(snapshot.lastError, message)

        let persistedStatus = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
        XCTAssertTrue(persistedStatus.contains("custom_key\tkeep-me"))
        XCTAssertTrue(persistedStatus.contains("last_error\t\(message)"))
    }

    func testNonzeroExitReplacesStaleErrorWithCurrentDiagnostic() throws {
        let fixture = try makeTaskFixture(
            status: staleWorkerStatus
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = TaskRunner(commandExecutor: { _, _, _ in
            CommandResult(exitCode: 7, stdout: "", stderr: "fresh process failure")
        })

        guard case .failure(let message, let snapshot) = runner.run(fixture.task) else {
            return XCTFail("Expected nonzero exit to fail")
        }

        XCTAssertEqual(message, "fresh process failure")
        XCTAssertEqual(snapshot.lastError, "fresh process failure")
    }

    func testRunnerConfigurationFailurePersistsDiagnostic() throws {
        let fixture = try makeTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.task.paths.scriptFile)

        let runner = TaskRunner()
        guard case .failure(let message, let snapshot) = runner.run(fixture.task) else {
            return XCTFail("Expected missing worker script to fail")
        }

        XCTAssertTrue(message.contains("needs a run.sh script"))
        XCTAssertEqual(snapshot.lastError, message)
    }

    func testTimeoutStopsWorkerProcessGroupAndPersistsError() throws {
        let fixture = try makeTaskFixture(
            script: sleepingWorkerScript,
            status: staleWorkerStatus
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = TaskRunner(executionTimeout: 0.15)
        let startedAt = Date()
        let outcome = runner.run(fixture.task)

        guard case .timedOut(let message, let snapshot) = outcome else {
            return XCTFail("Expected sleeping worker to time out")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        XCTAssertTrue(message.contains("timed out"))
        XCTAssertEqual(snapshot.lastError, message)
        XCTAssertNotEqual(snapshot.lastError, "stale worker failure")

        let persistedStatus = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
        XCTAssertTrue(persistedStatus.contains("last_error\t\(message)"))
        XCTAssertFalse(persistedStatus.contains("last_error\tstale worker failure"))

        let childPID = try readChildPID(from: fixture.task.paths.taskDirectory)
        XCTAssertTrue(
            waitForProcessToExit(childPID, timeout: 2),
            "Child remained after timeout: \(processDescription(childPID))"
        )
    }

    func testCancellationStopsWorkerProcessGroup() async throws {
        let fixture = try makeTaskFixture(
            script: sleepingWorkerScript,
            status: staleWorkerStatus
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let runner = TaskRunner(executionTimeout: 10)
        let execution = Task.detached {
            runner.run(fixture.task)
        }

        let childFile = fixture.task.paths.taskDirectory.appendingPathComponent("child.pid")
        let workerStarted = await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: childFile.path)
        }
        XCTAssertTrue(workerStarted)

        execution.cancel()
        let outcome = await execution.value

        guard case .cancelled(let snapshot) = outcome else {
            return XCTFail("Expected worker to be cancelled")
        }

        XCTAssertTrue(snapshot.lastError.contains("stopped before completion"))
        XCTAssertNotEqual(snapshot.lastError, "stale worker failure")
        let childPID = try readChildPID(from: fixture.task.paths.taskDirectory)
        XCTAssertTrue(
            waitForProcessToExit(childPID, timeout: 2),
            "Child remained after cancellation: \(processDescription(childPID))"
        )
    }

    func testCommandOutputIsDrainedAndBounded() {
        let result = CommandRunner.run(
            "/bin/zsh",
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 200000; print TAIL"],
            timeout: 5,
            outputLimit: 128
        )

        XCTAssertEqual(result.termination, .completed)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 128)
        XCTAssertTrue(result.stdout.hasSuffix("TAIL\n"))
    }

    private var sleepingWorkerScript: String {
        """
        #!/bin/zsh
        /bin/sleep 10 &
        child_pid=$!
        print -r -- "$child_pid" > "${0:h}/child.pid"
        wait "$child_pid"
        """
    }
}

final class CodexUsageLedgerIntegrationTests: XCTestCase {
    func testUnavailableRemoteDoesNotBlockHealthyTodayCollection() throws {
        guard
            executable(named: "jq") != nil,
            executable(named: "perl") != nil,
            let node = executable(named: "node")
        else {
            throw XCTSkip("Codex usage worker integration requires jq, perl, and Node.js")
        }

        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = TaskCatalog(appSupportDirectory: root)
        let usageTask = try XCTUnwrap(
            catalog.discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )

        let fakeLocal = root.appendingPathComponent("fake-ccusage")
        let fakeSSH = root.appendingPathComponent("fake-ssh")
        let fakeCodex = root.appendingPathComponent("fake-codex")
        let invocationLog = root.appendingPathComponent("ccusage-invocations.log")
        try fakeLocalUsageScript.write(to: fakeLocal, atomically: true, encoding: .utf8)
        try fakeRemoteUsageScript.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fakeCodexAppServerScript.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLocal.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            usageTask.paths.scriptFile.path,
            usageTask.paths.statusFile.path,
            usageTask.paths.logFile.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TINKERBAR_CODEX_USAGE_REMOTE_HOSTS"] = "offline remote-ok"
        environment["TINKERBAR_CODEX_USAGE_TIMEZONE"] = "UTC"
        environment["TINKERBAR_CODEX_USAGE_DISCOVERY_FLOOR_DATE"] = "2024-01-01"
        environment["TINKERBAR_CODEX_USAGE_FETCH_TIMEOUT_SECONDS"] = "5"
        environment["TINKERBAR_CODEX_USAGE_CCUSAGE_BIN"] = fakeLocal.path
        environment["TINKERBAR_CODEX_USAGE_CODEX_CLI_BIN"] = fakeCodex.path
        environment["TINKERBAR_CODEX_USAGE_NODE_BIN"] = node.path
        environment["TINKERBAR_CODEX_USAGE_SSH_BIN"] = fakeSSH.path
        environment["TINKERBAR_CODEX_USAGE_CONFIG_FILE"] = root.appendingPathComponent("no-config.env").path
        environment["TINKERBAR_TEST_CCUSAGE_ARGS_FILE"] = invocationLog.path
        environment["REBUILD_LEDGER"] = "0"
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)

        let summaryData = try Data(contentsOf: usageTask.paths.summaryFile)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: summaryData) as? [String: Any])
        let collection = try XCTUnwrap(summary["collection"] as? [String: Any])
        XCTAssertEqual(summary["ledgerSchemaVersion"] as? Int, 2)
        XCTAssertEqual(summary["costBasis"] as? String, "estimated_standard_api_equivalent")
        let collector = try XCTUnwrap(summary["collector"] as? [String: Any])
        XCTAssertEqual(collector["version"] as? String, "20.0.17")
        XCTAssertEqual(collector["speed"] as? String, "standard")
        let log = try String(contentsOf: usageTask.paths.logFile, encoding: .utf8)
        XCTAssertEqual(Set(collection["historicalFailedHosts"] as? [String] ?? []), Set(["offline"]), log)
        XCTAssertEqual(Set(collection["todayFailedHosts"] as? [String] ?? []), Set(["offline"]), log)

        let today = try XCTUnwrap(summary["today"] as? [String: Any])
        let todayHosts = Set((today["byHost"] as? [[String: Any]] ?? []).compactMap { $0["host"] as? String })
        XCTAssertEqual(todayHosts, Set(["local", "remote-ok"]))
        XCTAssertEqual(Set(today["unavailableHosts"] as? [String] ?? []), Set(["offline"]))
        XCTAssertEqual(try XCTUnwrap(today["totalCostUSD"] as? Double), 4, accuracy: 0.001)

        let ledger = try String(contentsOf: usageTask.paths.ledgerFile, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"host\":\"local\""))
        XCTAssertTrue(ledger.contains("\"host\":\"remote-ok\""))
        XCTAssertFalse(ledger.contains("\"host\":\"offline\""))
        XCTAssertTrue(ledger.contains("\"gpt-5.6-sol\""))
        XCTAssertTrue(ledger.contains("\"gpt-5.6-terra\""))
        XCTAssertTrue(ledger.contains("\"cacheReadTokens\""))
        XCTAssertFalse(ledger.contains("pricingAdjustment"))

        let models = try XCTUnwrap(summary["models"] as? [String: Any])
        XCTAssertEqual(
            Set(models["observedRecent"] as? [String] ?? []),
            Set(["gpt-5.6-sol", "gpt-5.6-terra"])
        )
        XCTAssertEqual(
            Set(models["currentCatalog"] as? [String] ?? []),
            Set(["gpt-5.6-sol", "gpt-5.6-luna"])
        )
        XCTAssertEqual(Set(models["notInCurrentCatalog"] as? [String] ?? []), [])
        let official = try XCTUnwrap(summary["official"] as? [String: Any])
        let officialModels = try XCTUnwrap(official["models"] as? [String: Any])
        XCTAssertEqual(officialModels["available"] as? Bool, true)
        let accountUsage = try XCTUnwrap(official["accountUsage"] as? [String: Any])
        XCTAssertEqual(accountUsage["available"] as? Bool, true)

        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
        XCTAssertTrue(invocations.contains("codex daily --json --offline --speed standard"), invocations)
        XCTAssertTrue(invocations.contains("npx --yes 'ccusage@20.0.17' codex daily"), invocations)

        let snapshot = try XCTUnwrap(
            CodexUsageSnapshot.load(
                summaryFile: usageTask.paths.summaryFile,
                ledgerFile: usageTask.paths.ledgerFile
            )
        )
        XCTAssertEqual(snapshot.partialDataText, "Partial data; unavailable: Offline")
        XCTAssertTrue(snapshot.estimateNoticeText.contains("ccusage 20.0.17"))
        XCTAssertEqual(snapshot.modelSummaryText, "Recent models: gpt-5.6-sol, gpt-5.6-terra")
        XCTAssertNotNil(snapshot.officialUsageText)
        XCTAssertEqual(snapshot.totalRow.today, "≥$4")
        let offlineRow = try XCTUnwrap(snapshot.hostRows.first(where: { $0.id == "offline" }))
        XCTAssertEqual(offlineRow.allTime, "≥$0")
        XCTAssertEqual(offlineRow.monthToDate, "≥$0")
        XCTAssertEqual(offlineRow.yesterday, "—")
        XCTAssertEqual(offlineRow.today, "—")

        let status = try String(contentsOf: usageTask.paths.statusFile, encoding: .utf8)
        XCTAssertTrue(status.contains("last_error\tFailed to collect offline usage"))
        XCTAssertTrue(status.contains("last_output\tPartial collection"))
    }

    func testLegacyLedgerMigrationCommitsAtomicallyAndKeepsBackup() throws {
        guard executable(named: "jq") != nil, executable(named: "perl") != nil else {
            throw XCTSkip("Codex usage worker requires jq and perl")
        }

        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerMigrationTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let usageTask = try XCTUnwrap(
            TaskCatalog(appSupportDirectory: root)
                .discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )
        let fakeLocal = root.appendingPathComponent("fake-ccusage")
        try fakeLocalUsageScript.write(to: fakeLocal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLocal.path)

        let legacyLedger = """
        {"date":"\(utcDateString(daysFromToday: -1))","host":"local","costUSD":9999,"totalTokens":1,"pricingAdjustment":{"mode":"legacy"}}

        """
        try legacyLedger.write(to: usageTask.paths.ledgerFile, atomically: true, encoding: .utf8)

        let exitCode = try runLedgerWorker(
            usageTask,
            root: root,
            localCollector: fakeLocal
        )
        XCTAssertEqual(exitCode, 0)

        let rebuiltLedger = try String(contentsOf: usageTask.paths.ledgerFile, encoding: .utf8)
        XCTAssertNotEqual(rebuiltLedger, legacyLedger)
        XCTAssertTrue(rebuiltLedger.contains("\"ledgerSchemaVersion\":2"))
        XCTAssertTrue(rebuiltLedger.contains("\"version\":\"20.0.17\""))
        XCTAssertFalse(rebuiltLedger.contains("pricingAdjustment"))
        XCTAssertFalse(rebuiltLedger.contains("9999"))

        let rebuiltSummaryData = try Data(contentsOf: usageTask.paths.summaryFile)
        let rebuiltSummary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rebuiltSummaryData) as? [String: Any]
        )
        XCTAssertEqual(rebuiltSummary["ledgerSchemaVersion"] as? Int, 2)
        let rebuiltGeneration = try XCTUnwrap(rebuiltSummary["ledgerGeneration"] as? String)
        XCTAssertEqual(
            (rebuiltSummary["collector"] as? [String: Any])?["version"] as? String,
            "20.0.17"
        )
        let rebuiltFirstRow = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(rebuiltLedger.split(separator: "\n").first).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(rebuiltFirstRow["ledgerGeneration"] as? String, rebuiltGeneration)

        let backups = try FileManager.default.contentsOfDirectory(
            at: usageTask.paths.taskDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("ledger.jsonl.rebuild-") &&
                $0.pathExtension == "bak"
        }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), legacyLedger)
    }

    func testFailedLegacyLedgerMigrationRetainsOriginalWithoutBackupSwap() throws {
        guard executable(named: "jq") != nil, executable(named: "perl") != nil else {
            throw XCTSkip("Codex usage worker requires jq and perl")
        }

        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerRollbackTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let usageTask = try XCTUnwrap(
            TaskCatalog(appSupportDirectory: root)
                .discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )
        let fakeLocal = root.appendingPathComponent("fake-ccusage")
        let fakeSSH = root.appendingPathComponent("fake-ssh")
        try fakeLocalUsageScript.write(to: fakeLocal, atomically: true, encoding: .utf8)
        try fakeRemoteUsageScript.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLocal.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let legacyLedger = """
        {"date":"\(utcDateString(daysFromToday: -1))","host":"local","costUSD":9999,"totalTokens":1,"pricingAdjustment":{"mode":"legacy"}}

        """
        try legacyLedger.write(to: usageTask.paths.ledgerFile, atomically: true, encoding: .utf8)

        let exitCode = try runLedgerWorker(
            usageTask,
            root: root,
            localCollector: fakeLocal,
            remoteCollector: fakeSSH,
            remoteHosts: "offline"
        )
        XCTAssertEqual(exitCode, 1)
        XCTAssertEqual(
            try String(contentsOf: usageTask.paths.ledgerFile, encoding: .utf8),
            legacyLedger
        )

        let backupNames = try FileManager.default.contentsOfDirectory(
            atPath: usageTask.paths.taskDirectory.path
        ).filter { $0.hasPrefix("ledger.jsonl.rebuild-") && $0.hasSuffix(".bak") }
        XCTAssertTrue(backupNames.isEmpty)

        let status = try String(contentsOf: usageTask.paths.statusFile, encoding: .utf8)
        XCTAssertTrue(status.contains("Ledger rebuild not committed"), status)
        XCTAssertTrue(status.contains("Previous ledger retained"), status)
    }

    func testTruncatedRebuildCoverageCannotReplaceEarlierHistory() throws {
        guard executable(named: "jq") != nil, executable(named: "perl") != nil else {
            throw XCTSkip("Codex usage worker requires jq and perl")
        }

        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerCoverageTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let usageTask = try XCTUnwrap(
            TaskCatalog(appSupportDirectory: root)
                .discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )
        let fakeLocal = root.appendingPathComponent("fake-ccusage")
        try fakeLocalUsageScript.write(to: fakeLocal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLocal.path)

        let legacyLedger = """
        {"date":"2026-01-01","host":"local","costUSD":1,"totalTokens":1}

        """
        try legacyLedger.write(to: usageTask.paths.ledgerFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try runLedgerWorker(usageTask, root: root, localCollector: fakeLocal),
            1
        )
        XCTAssertEqual(
            try String(contentsOf: usageTask.paths.ledgerFile, encoding: .utf8),
            legacyLedger
        )
        let log = try String(contentsOf: usageTask.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("Incomplete usage coverage from local"), log)
    }

    func testEmptyRebuildResponseCannotEraseExistingHostHistory() throws {
        guard executable(named: "jq") != nil, executable(named: "perl") != nil else {
            throw XCTSkip("Codex usage worker requires jq and perl")
        }

        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerEmptyRebuildTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let usageTask = try XCTUnwrap(
            TaskCatalog(appSupportDirectory: root)
                .discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )
        let emptyCollector = root.appendingPathComponent("empty-ccusage")
        try "#!/bin/zsh\nprint -r -- '{\"daily\":[],\"totals\":{}}'\n".write(
            to: emptyCollector,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: emptyCollector.path
        )

        let legacyLedger = """
        {"date":"2026-01-01","host":"local","costUSD":9999,"totalTokens":1}

        """
        try legacyLedger.write(to: usageTask.paths.ledgerFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try runLedgerWorker(
                usageTask,
                root: root,
                localCollector: emptyCollector
            ),
            1
        )
        XCTAssertEqual(
            try String(contentsOf: usageTask.paths.ledgerFile, encoding: .utf8),
            legacyLedger
        )
        let status = try String(contentsOf: usageTask.paths.statusFile, encoding: .utf8)
        let log = try String(contentsOf: usageTask.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("Empty usage response from local"), log)
        XCTAssertTrue(status.contains("Ledger rebuild not committed"), status)
        XCTAssertTrue(status.contains("Previous ledger retained"), status)
    }

    func testLegacySnapshotSuppressesKnownInvalidDollarTotals() throws {
        let root = try makeTemporaryDirectory(prefix: "TinkerBarLegacySnapshotTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let summaryFile = root.appendingPathComponent("latest-summary.json")
        let ledgerFile = root.appendingPathComponent("ledger.jsonl")

        try #"{"timezone":"UTC","latestRecordedDate":"2026-07-13","collection":{"expectedHosts":["local"],"historicalFailedHosts":[]},"monthToDate":{"totalCostUSD":6855.45,"byHost":[{"host":"local","totalCostUSD":6855.45}]},"latestByHost":[{"host":"local","costUSD":9999}],"today":{"totalCostUSD":950.29,"byHost":[{"host":"local","costUSD":950.29}],"unavailableHosts":[]}}"#.write(
            to: summaryFile,
            atomically: true,
            encoding: .utf8
        )
        try #"{"date":"2026-07-13","host":"local","costUSD":9999}"#.write(
            to: ledgerFile,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try XCTUnwrap(
            CodexUsageSnapshot.load(summaryFile: summaryFile, ledgerFile: ledgerFile)
        )
        XCTAssertEqual(snapshot.totalRow.allTime, "—")
        XCTAssertEqual(snapshot.totalRow.monthToDate, "—")
        XCTAssertEqual(snapshot.totalRow.today, "—")
        XCTAssertFalse(snapshot.isEstimateAvailable)
        XCTAssertEqual(snapshot.availabilityMessageText, "Codex ledger rebuild required")
        XCTAssertEqual(snapshot.menuBarBadgeText, "TinkerBar")
        XCTAssertEqual(snapshot.todayMenuBarBadgeText, "TinkerBar")
        XCTAssertTrue(snapshot.estimateNoticeText.contains("rebuild is required"))
    }

    func testMalformedOptionalOfficialUsageDoesNotHideValidEstimate() throws {
        let root = try makeTemporaryDirectory(prefix: "TinkerBarOfficialUsageDecodeTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let summaryFile = root.appendingPathComponent("latest-summary.json")
        let ledgerFile = root.appendingPathComponent("ledger.jsonl")

        try #"{"ledgerSchemaVersion":2,"ledgerGeneration":"generation-a","rows":1,"timezone":"UTC","collector":{"version":"20.0.17","speed":"standard"},"models":{"observedRecent":["gpt-5.6-sol"],"catalogAvailable":true,"notInCurrentCatalog":[],"fallbackAttributed":[],"possiblyUnpricedRows":[]},"official":{"probeWarning":42,"accountUsage":{"available":true,"dailyUsageBuckets":[{"startDate":42,"tokens":"bad"}]}},"latestRecordedDate":"2026-07-13","collection":{"expectedHosts":["local"],"historicalFailedHosts":[]},"monthToDate":{"totalCostUSD":1.25,"byHost":[{"host":"local","totalCostUSD":1.25}]},"latestByHost":[{"host":"local","costUSD":1.25}],"yesterday":{"totalCostUSD":1.25,"byHost":[{"host":"local","costUSD":1.25}]},"today":{"totalCostUSD":0,"byHost":[],"unavailableHosts":[]}}"#.write(
            to: summaryFile,
            atomically: true,
            encoding: .utf8
        )
        try #"{"ledgerSchemaVersion":2,"ledgerGeneration":"generation-a","date":"2026-07-13","host":"local","costUSD":1.25}"#.write(
            to: ledgerFile,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try XCTUnwrap(
            CodexUsageSnapshot.load(summaryFile: summaryFile, ledgerFile: ledgerFile)
        )
        XCTAssertEqual(snapshot.totalRow.allTime, "$1")
        XCTAssertTrue(snapshot.isEstimateAvailable)
        XCTAssertNil(snapshot.officialUsageText)
        XCTAssertEqual(snapshot.modelSummaryText, "Recent models: gpt-5.6-sol")
    }

    func testMismatchedLedgerGenerationSuppressesMixedSnapshot() throws {
        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerGenerationTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let summaryFile = root.appendingPathComponent("latest-summary.json")
        let ledgerFile = root.appendingPathComponent("ledger.jsonl")

        try #"{"ledgerSchemaVersion":2,"ledgerGeneration":"summary-generation","rows":1,"timezone":"UTC","collector":{"version":"20.0.17","speed":"standard"},"latestRecordedDate":"2026-07-13","collection":{"expectedHosts":["local"],"historicalFailedHosts":[]},"monthToDate":{"totalCostUSD":9999,"byHost":[{"host":"local","totalCostUSD":9999}]},"latestByHost":[{"host":"local","costUSD":9999}],"today":{"totalCostUSD":9999,"byHost":[{"host":"local","costUSD":9999}],"unavailableHosts":[]}}"#.write(
            to: summaryFile,
            atomically: true,
            encoding: .utf8
        )
        try #"{"ledgerSchemaVersion":2,"ledgerGeneration":"ledger-generation","date":"2026-07-13","host":"local","costUSD":1.25}"#.write(
            to: ledgerFile,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try XCTUnwrap(
            CodexUsageSnapshot.load(summaryFile: summaryFile, ledgerFile: ledgerFile)
        )
        XCTAssertFalse(snapshot.isEstimateAvailable)
        XCTAssertEqual(snapshot.totalRow.allTime, "—")
        XCTAssertEqual(
            snapshot.availabilityMessageText,
            "Codex ledger update incomplete; run the usage task again."
        )
    }

    func testBuiltInUsageTaskMigratesOnlyTheLegacyDetailPrefix() throws {
        let root = try makeTemporaryDirectory(prefix: "TinkerBarUsageConfigMigrationTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let taskDirectory = root
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("codex-usage-ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)

        let configuration = AutomationTaskConfiguration(
            id: "codex-usage-ledger",
            name: "Codex Usage Ledger",
            detail: "Track Codex spend for this Mac, Andrew, and Mac Mini.",
            scriptKind: nil,
            triggerKind: .interval,
            directoryPath: nil,
            intervalSeconds: 1_800,
            openPath: "~/custom-ledger"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(
            to: taskDirectory.appendingPathComponent("task.json")
        )

        let usageTask = try XCTUnwrap(
            TaskCatalog(appSupportDirectory: root)
                .discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )
        XCTAssertEqual(
            usageTask.configuration.detail,
            "Track estimated Codex API-equivalent cost for this Mac, Andrew, and Mac Mini."
        )
        XCTAssertEqual(usageTask.configuration.scriptKind, "codex_usage_ledger")
        XCTAssertEqual(usageTask.configuration.openPath, "~/custom-ledger")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: usageTask.paths.taskDirectory
                    .appendingPathComponent("codex-usage-app-server.mjs")
                    .path
            )
        )
    }

    func testCancellationStopsNestedUsageFetchProcessGroup() async throws {
        guard executable(named: "jq") != nil, executable(named: "perl") != nil else {
            throw XCTSkip("Codex usage worker requires jq and perl")
        }

        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerCancellationTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = TaskCatalog(appSupportDirectory: root)
        let usageTask = try XCTUnwrap(
            catalog.discoverTasks().tasks.first(where: { $0.id == "codex-usage-ledger" })
        )
        let taskDirectory = usageTask.paths.taskDirectory
        let ledgerWorker = taskDirectory.appendingPathComponent("ledger-worker.sh")
        let fakeLocal = taskDirectory.appendingPathComponent("fake-ccusage")
        let fakeSSH = taskDirectory.appendingPathComponent("fake-ssh")
        let processIDsFile = taskDirectory.appendingPathComponent("nested-processes.pid")

        try FileManager.default.copyItem(at: usageTask.paths.scriptFile, to: ledgerWorker)
        try "#!/bin/zsh\nprint -r -- '{\"daily\":[],\"totals\":{}}'\n".write(
            to: fakeLocal,
            atomically: true,
            encoding: .utf8
        )
        try nestedProcessUsageScript.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLocal.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let wrapper = """
        #!/bin/zsh
        export TINKERBAR_CODEX_USAGE_REMOTE_HOSTS=slow
        export TINKERBAR_CODEX_USAGE_TIMEZONE=UTC
        export TINKERBAR_CODEX_USAGE_DISCOVERY_FLOOR_DATE=9999-12-31
        export TINKERBAR_CODEX_USAGE_FETCH_TIMEOUT_SECONDS=60
        export TINKERBAR_CODEX_USAGE_CCUSAGE_BIN=\(shellQuoted(fakeLocal.path))
        export TINKERBAR_CODEX_USAGE_SSH_BIN=\(shellQuoted(fakeSSH.path))
        export TINKERBAR_CODEX_USAGE_CONFIG_FILE=\(shellQuoted(taskDirectory.appendingPathComponent("no-config.env").path))
        export TINKERBAR_CODEX_USAGE_OFFICIAL_PROBE_ENABLED=0
        export TINKERBAR_TEST_NESTED_PROCESS_IDS=\(shellQuoted(processIDsFile.path))
        exec /bin/zsh \(shellQuoted(ledgerWorker.path)) "$@"
        """
        try wrapper.write(to: usageTask.paths.scriptFile, atomically: true, encoding: .utf8)

        let runner = TaskRunner(executionTimeout: 10)
        let execution = Task.detached {
            runner.run(usageTask)
        }

        let fetchStarted = await waitUntil(timeout: 3) {
            (try? readProcessIDs(from: processIDsFile).count) == 2
        }
        XCTAssertTrue(fetchStarted, "Nested usage fetch did not start")

        let processIDs = try readProcessIDs(from: processIDsFile)
        XCTAssertEqual(processIDs.count, 2)
        execution.cancel()

        guard case .cancelled = await execution.value else {
            return XCTFail("Expected usage collection to be cancelled")
        }

        let log = (try? String(contentsOf: usageTask.paths.logFile, encoding: .utf8)) ?? "<missing log>"
        for processID in processIDs {
            XCTAssertTrue(
                waitForProcessToExit(processID, timeout: 2),
                "Nested process remained after cancellation: \(processDescription(processID))\n\(log)"
            )
        }
    }

    private var fakeLocalUsageScript: String {
        #"""
        #!/bin/zsh
        if [[ -n "${TINKERBAR_TEST_CCUSAGE_ARGS_FILE:-}" ]]; then
          print -r -- "$*" >> "$TINKERBAR_TEST_CCUSAGE_ARGS_FILE"
        fi
        yesterday=$(TZ=UTC /bin/date -v-1d "+%Y-%m-%d")
        today=$(TZ=UTC /bin/date "+%Y-%m-%d")
        target_date="$yesterday"
        if [[ " $* " == *" --since $today "* ]]; then
          target_date="$today"
        fi
        print -r -- "{\"daily\":[{\"date\":\"$target_date\",\"inputTokens\":1,\"cacheCreationTokens\":0,\"cacheReadTokens\":3,\"outputTokens\":1,\"reasoningOutputTokens\":0,\"totalTokens\":5,\"costUSD\":1.25,\"models\":{\"gpt-5.6-sol\":{\"inputTokens\":1,\"cacheCreationTokens\":0,\"cacheReadTokens\":3,\"outputTokens\":1,\"reasoningOutputTokens\":0,\"totalTokens\":5,\"isFallback\":false}}}],\"totals\":{\"inputTokens\":1,\"cacheCreationTokens\":0,\"cacheReadTokens\":3,\"outputTokens\":1,\"reasoningOutputTokens\":0,\"totalTokens\":5,\"costUSD\":1.25}}"
        """#
    }

    private var fakeRemoteUsageScript: String {
        #"""
        #!/bin/zsh
        host=""
        for argument in "$@"; do
          case "$argument" in
            offline|remote-ok) host="$argument" ;;
          esac
        done
        if [[ "$host" == "offline" ]]; then
          exit 23
        fi
        payload=$(/bin/cat)
        if [[ -n "${TINKERBAR_TEST_CCUSAGE_ARGS_FILE:-}" ]]; then
          print -r -- "$payload" >> "$TINKERBAR_TEST_CCUSAGE_ARGS_FILE"
        fi
        yesterday=$(TZ=UTC /bin/date -v-1d "+%Y-%m-%d")
        today=$(TZ=UTC /bin/date "+%Y-%m-%d")
        target_date="$yesterday"
        if [[ "$payload" == *"--since '$today' --until '$today'"* ]]; then
          target_date="$today"
        fi
        print -r -- "{\"daily\":[{\"date\":\"$target_date\",\"inputTokens\":2,\"cacheCreationTokens\":0,\"cacheReadTokens\":4,\"outputTokens\":1,\"reasoningOutputTokens\":0,\"totalTokens\":7,\"costUSD\":2.75,\"models\":{\"gpt-5.6-terra\":{\"inputTokens\":2,\"cacheCreationTokens\":0,\"cacheReadTokens\":4,\"outputTokens\":1,\"reasoningOutputTokens\":0,\"totalTokens\":7,\"isFallback\":false}}}],\"totals\":{\"inputTokens\":2,\"cacheCreationTokens\":0,\"cacheReadTokens\":4,\"outputTokens\":1,\"reasoningOutputTokens\":0,\"totalTokens\":7,\"costUSD\":2.75}}"
        """#
    }

    private var fakeCodexAppServerScript: String {
        #"""
        #!/bin/zsh
        emulate -LR zsh
        set -euo pipefail

        IFS= read -r initialize
        initialize_id=$(print -r -- "$initialize" | jq -r '.id')
        print -r -- "{\"id\":$initialize_id,\"result\":{\"userAgent\":\"fake\"}}"

        IFS= read -r initialized
        IFS= read -r first_request
        IFS= read -r second_request

        first_method=$(print -r -- "$first_request" | jq -r '.method')
        if [[ "$first_method" == "model/list" ]]; then
          model_request="$first_request"
          usage_request="$second_request"
        else
          model_request="$second_request"
          usage_request="$first_request"
        fi

        usage_id=$(print -r -- "$usage_request" | jq -r '.id')
        today=$(TZ=UTC /bin/date "+%Y-%m-%d")
        print -r -- "{\"id\":$usage_id,\"result\":{\"summary\":{\"lifetimeTokens\":12345},\"dailyUsageBuckets\":[{\"startDate\":\"$today\",\"tokens\":12345}]}}"

        model_id=$(print -r -- "$model_request" | jq -r '.id')
        print -r -- "{\"id\":$model_id,\"result\":{\"data\":[{\"id\":\"gpt-5.6-sol\",\"model\":\"gpt-5.6-sol\",\"displayName\":\"GPT-5.6 Sol\",\"hidden\":false}],\"nextCursor\":\"page-2\"}}"

        IFS= read -r next_page
        next_page_id=$(print -r -- "$next_page" | jq -r '.id')
        print -r -- "{\"id\":$next_page_id,\"result\":{\"data\":[{\"id\":\"gpt-5.6-luna\",\"model\":\"gpt-5.6-luna\",\"displayName\":\"GPT-5.6 Luna\",\"hidden\":false}],\"nextCursor\":null}}"
        """#
    }

    private func runLedgerWorker(
        _ usageTask: AutomationTaskState,
        root: URL,
        localCollector: URL,
        remoteCollector: URL? = nil,
        remoteHosts: String = ""
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            usageTask.paths.scriptFile.path,
            usageTask.paths.statusFile.path,
            usageTask.paths.logFile.path,
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["TINKERBAR_CODEX_USAGE_REMOTE_HOSTS"] = remoteHosts
        environment["TINKERBAR_CODEX_USAGE_TIMEZONE"] = "UTC"
        environment["TINKERBAR_CODEX_USAGE_DISCOVERY_FLOOR_DATE"] = "2024-01-01"
        environment["TINKERBAR_CODEX_USAGE_FETCH_TIMEOUT_SECONDS"] = "5"
        environment["TINKERBAR_CODEX_USAGE_CCUSAGE_BIN"] = localCollector.path
        environment["TINKERBAR_CODEX_USAGE_SSH_BIN"] = remoteCollector?.path ?? "/usr/bin/false"
        environment["TINKERBAR_CODEX_USAGE_CONFIG_FILE"] = root
            .appendingPathComponent("no-config.env").path
        environment["TINKERBAR_CODEX_USAGE_OFFICIAL_PROBE_ENABLED"] = "0"
        environment["REBUILD_LEDGER"] = "0"
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func utcDateString(daysFromToday offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(byAdding: .day, value: offset, to: Date())!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var nestedProcessUsageScript: String {
        #"""
        #!/bin/zsh
        /bin/sleep 30 &
        child_pid=$!
        print -r -- "$$ $child_pid" > "$TINKERBAR_TEST_NESTED_PROCESS_IDS"
        wait "$child_pid"
        """#
    }
}

final class AutomationRuntimeCancellationTests: XCTestCase {
    @MainActor
    func testRuntimeCancellationReturnsTaskToIdle() async throws {
        let root = try makeTemporaryDirectory(prefix: "TinkerBarRuntimeCancellationTests")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeCatalogTask(appSupportDirectory: root)
        let executor = CancellationAwareExecutor()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: root, installsBuiltInTasks: false),
            runner: TaskRunner(executionTimeout: 10, commandExecutor: executor.execute),
            autoload: false,
            loadStartupState: false
        )
        runtime.reloadTasks()

        runtime.runTaskNow("cancel-me")
        let started = await waitUntilOnMainActor(timeout: 2) {
            executor.callCount == 1 && runtime.tasks.first?.isRunning == true
        }
        XCTAssertTrue(started)

        runtime.cancelTaskRun("cancel-me")
        let stopped = await waitUntilOnMainActor(timeout: 2) {
            runtime.tasks.first?.isRunning == false
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(runtime.message, "Cancel Me stopped.")
    }
}

private struct TaskFixture {
    let root: URL
    let task: AutomationTaskState
}

private final class CancellationAwareExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func execute(
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> CommandResult {
        lock.lock()
        calls += 1
        lock.unlock()

        while !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }

        return CommandResult(exitCode: 143, stdout: "", stderr: "", termination: .cancelled)
    }
}

private func makeTaskFixture(
    script: String = "#!/bin/zsh\nexit 0\n",
    status: String = """
    last_run_iso\t
    last_success_iso\t
    success_count\t0
    last_output\t
    last_error\t
    """
) throws -> TaskFixture {
    let root = try makeTemporaryDirectory(prefix: "TinkerBarRunnerTests")
    let taskDirectory = root.appendingPathComponent("task", isDirectory: true)
    try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)

    let paths = AutomationTaskPaths(taskDirectory: taskDirectory)
    try script.write(to: paths.scriptFile, atomically: true, encoding: .utf8)
    try status.write(to: paths.statusFile, atomically: true, encoding: .utf8)

    let configuration = AutomationTaskConfiguration(
        id: "reliability-task",
        name: "Reliability Task",
        detail: "Test task",
        scriptKind: nil,
        triggerKind: .interval,
        directoryPath: nil,
        intervalSeconds: 60,
        openPath: nil
    )
    let task = AutomationTaskState(
        configuration: configuration,
        paths: paths,
        snapshot: TaskStatusStore.snapshot(for: paths),
        isEnabled: true,
        isRunning: false
    )
    return TaskFixture(root: root, task: task)
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeCatalogTask(appSupportDirectory: URL) throws {
    let taskDirectory = appSupportDirectory
        .appendingPathComponent("tasks", isDirectory: true)
        .appendingPathComponent("cancel-me", isDirectory: true)
    try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)

    let paths = AutomationTaskPaths(taskDirectory: taskDirectory)
    let configuration = AutomationTaskConfiguration(
        id: "cancel-me",
        name: "Cancel Me",
        detail: "Cancellation test",
        scriptKind: nil,
        triggerKind: .interval,
        directoryPath: nil,
        intervalSeconds: 60,
        openPath: nil
    )
    let encoder = JSONEncoder()
    try encoder.encode(configuration).write(to: paths.configFile)
    try "#!/bin/zsh\nexit 0\n".write(to: paths.scriptFile, atomically: true, encoding: .utf8)
}

private func readChildPID(from directory: URL) throws -> pid_t {
    let value = try String(
        contentsOf: directory.appendingPathComponent("child.pid"),
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return try XCTUnwrap(pid_t(value))
}

private func readProcessIDs(from file: URL) throws -> [pid_t] {
    let values = try String(contentsOf: file, encoding: .utf8)
        .split(whereSeparator: { $0.isWhitespace })
    return try values.map { value in
        try XCTUnwrap(pid_t(value))
    }
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func waitForProcessToExit(_ processID: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processExists(processID) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return !processExists(processID)
}

private func processExists(_ processID: pid_t) -> Bool {
    Darwin.kill(processID, 0) == 0 || errno == EPERM
}

private func processDescription(_ processID: pid_t) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(processID), "-o", "pid=,ppid=,pgid=,state=,command="]
    process.standardOutput = output
    try? process.run()
    process.waitUntilExit()
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
private func waitUntilOnMainActor(
    timeout: TimeInterval,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func executable(named name: String) -> URL? {
    let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    for directory in pathDirectories {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}
