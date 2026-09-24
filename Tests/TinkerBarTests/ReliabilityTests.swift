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
    func testRunnerFailuresPublishAuthoritativeDiagnostics() throws {
        let cases: [(script: String?, previousError: String, diagnostic: String)] = [
            ("exit 0", "worker reported failure", "worker reported failure"),
            ("exit 7", "", "Reliability Task exited with status 7. Open the task log for details."),
            ("print -u2 -- 'fresh process failure'; exit 7", "stale worker failure", "fresh process failure"),
            (nil, "", "needs a run.sh script"),
        ]
        for scenario in cases {
            let fixture = try makeTaskFixture(
                script: scenario.script ?? "",
                status: "last_error\t\(scenario.previousError)\ncustom_key\tkeep-me\n"
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if scenario.script == nil {
                try FileManager.default.removeItem(at: fixture.task.paths.scriptFile)
            }

            guard case .failure(let message, let snapshot) = TaskRunner().run(fixture.task) else {
                XCTFail("Expected failure: \(scenario.diagnostic)")
                continue
            }
            let expected = scenario.script == nil
                ? "Reliability Task needs a run.sh script in \(fixture.task.paths.taskDirectory.path)."
                : scenario.diagnostic
            XCTAssertEqual(message, expected)
            XCTAssertEqual(snapshot.lastError, message)
            let persisted = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
            XCTAssertTrue(persisted.contains("last_error\t\(message)"), persisted)
            XCTAssertTrue(persisted.contains("custom_key\tkeep-me"), persisted)
        }
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

        let persistedStatus = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
        XCTAssertTrue(persistedStatus.contains("last_error\t\(message)"))
        XCTAssertFalse(persistedStatus.contains("last_error\tstale worker failure"))

        let childPID = try readChildPID(from: fixture.task.paths.taskDirectory)
        XCTAssertTrue(
            waitForProcessToExit(childPID, timeout: 2),
            "Child remained after timeout: \(processDescription(childPID))"
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
}

final class CodexUsageLedgerIntegrationTests: XCTestCase {
    func testLedgerMigrationsRebuildInvalidEstimatesAndKeepBackup() throws {
        for migration in ["schema", "offline"] {
            let fixture = try makeLedgerFixture(
                collectorScript: migration == "offline"
                    ? fakeLocalUsageScript.replacingOccurrences(of: "1.25", with: "0")
                    : fakeLocalUsageScript
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let collector: [String: Any] = [
                "version": "20.0.20", "speed": "standard",
                "pricingSource": migration == "offline" ? "embedded_offline" : "online_with_embedded_fallback",
            ]
            var old: [String: Any] = [
                "ledgerSchemaVersion": 2, "ledgerGeneration": "old", "date": utcDateString(daysFromToday: -1),
                "host": "local", "timezone": "UTC", "costUSD": 9999, "totalTokens": 5,
                "costBasis": "estimated_standard_api_equivalent", "collector": collector,
            ]
            if migration == "schema" {
                old.removeValue(forKey: "ledgerSchemaVersion")
                old["pricingAdjustment"] = ["mode": "legacy"]
            }
            let oldRow = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
            try oldRow.write(to: fixture.task.paths.ledgerFile, atomically: true, encoding: .utf8)

            XCTAssertEqual(try runLedgerWorker(fixture.task, root: fixture.root, localCollector: fixture.collector), 0, migration)
            let rebuilt = try String(contentsOf: fixture.task.paths.ledgerFile, encoding: .utf8)
            let row = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(rebuilt.split(separator: "\n").first).utf8)
            ) as? [String: Any])
            let summary = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.task.paths.summaryFile)
            ) as? [String: Any])
            let generation = try XCTUnwrap(summary["ledgerGeneration"] as? String)
            XCTAssertNotEqual(generation, "old", migration)
            XCTAssertEqual(row["ledgerGeneration"] as? String, generation, migration)
            XCTAssertEqual(row["ledgerSchemaVersion"] as? Int, 2, migration)
            XCTAssertEqual(summary["ledgerSchemaVersion"] as? Int, 2, migration)
            XCTAssertEqual((row["collector"] as? [String: Any])?["version"] as? String, "20.0.20", migration)
            XCTAssertEqual((summary["collector"] as? [String: Any])?["version"] as? String, "20.0.20", migration)
            XCTAssertEqual((row["collector"] as? [String: Any])?["pricingSource"] as? String, "online_with_embedded_fallback", migration)
            XCTAssertNil(row["pricingAdjustment"], migration)
            XCTAssertFalse(rebuilt.contains("9999"), migration)
            let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.task.paths.taskDirectory.path)
                .filter { $0.hasPrefix("ledger.jsonl.rebuild-") && $0.hasSuffix(".bak") }
            XCTAssertEqual(backups.count, 1, migration)
            let backup = fixture.task.paths.taskDirectory.appendingPathComponent(try XCTUnwrap(backups.first))
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), oldRow, migration)
            if migration == "offline" {
                let status = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
                XCTAssertTrue(status.contains("today Unpriced"), status)
                XCTAssertTrue(status.contains("MTD estimate Unpriced"), status)
                let snapshot = try XCTUnwrap(CodexUsageSnapshot.load(
                    summaryFile: fixture.task.paths.summaryFile, ledgerFile: fixture.task.paths.ledgerFile
                ))
                XCTAssertEqual(snapshot.totalRow.today, "Unpriced")
                XCTAssertEqual(snapshot.todayMenuBarBadgeText, "Unpriced")
            }
        }
    }

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
        XCTAssertEqual(collector["version"] as? String, "20.0.20")
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
        XCTAssertTrue(invocations.contains("codex daily --json --no-offline --speed standard"), invocations)
        XCTAssertTrue(invocations.contains("npx --yes 'ccusage@20.0.20' codex daily"), invocations)

        let snapshot = try XCTUnwrap(
            CodexUsageSnapshot.load(
                summaryFile: usageTask.paths.summaryFile,
                ledgerFile: usageTask.paths.ledgerFile
            )
        )
        XCTAssertEqual(snapshot.partialDataText, "Partial data; unavailable: Offline")
        XCTAssertTrue(snapshot.estimateNoticeText.contains("ccusage 20.0.20"))
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

    func testIncompleteRebuildsRetainOriginalHistory() throws {
        for (failure, diagnostic) in [
            ("offline", "Failed to collect offline usage"),
            ("truncated", "Incomplete usage coverage from local"),
            ("empty", "Empty usage response from local"),
        ] {
            let fixture = try makeLedgerFixture(
                collectorScript: failure == "empty"
                    ? "#!/bin/zsh\nprint -r -- '{\"daily\":[],\"totals\":{}}'\n"
                    : fakeLocalUsageScript
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let remoteCollector = fixture.root.appendingPathComponent("fake-ssh")
            try fakeRemoteUsageScript.write(to: remoteCollector, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remoteCollector.path)
            let oldDate = failure == "offline" ? utcDateString(daysFromToday: -1) : "2026-01-01"
            let legacyLedger = "{\"date\":\"\(oldDate)\",\"host\":\"local\",\"costUSD\":9999,\"totalTokens\":1}\n"
            try legacyLedger.write(to: fixture.task.paths.ledgerFile, atomically: true, encoding: .utf8)

            XCTAssertEqual(try runLedgerWorker(
                fixture.task, root: fixture.root, localCollector: fixture.collector,
                remoteCollector: remoteCollector, remoteHosts: failure == "offline" ? "offline" : ""
            ), 1, failure)
            XCTAssertEqual(try String(contentsOf: fixture.task.paths.ledgerFile, encoding: .utf8), legacyLedger, failure)
            let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.task.paths.taskDirectory.path)
                .filter { $0.hasPrefix("ledger.jsonl.rebuild-") && $0.hasSuffix(".bak") }
            XCTAssertTrue(backups.isEmpty, failure)
            let log = try String(contentsOf: fixture.task.paths.logFile, encoding: .utf8)
            XCTAssertTrue(log.contains(diagnostic), log)
            let status = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
            XCTAssertTrue(status.contains("Ledger rebuild not committed"), status)
            XCTAssertTrue(status.contains("Previous ledger retained"), status)
        }
    }

    func testUntrustedSnapshotsSuppressDollarTotals() throws {
        let cases: [(schema: Int?, generation: String, message: String)] = [
            (nil, "generation-a", "Codex ledger rebuild required"),
            (2, "generation-b", "Codex ledger update incomplete; run the usage task again."),
        ]
        for scenario in cases {
            let root = try makeTemporaryDirectory(prefix: "TinkerBarSnapshotIntegrityTests")
            defer { try? FileManager.default.removeItem(at: root) }
            let summaryFile = root.appendingPathComponent("latest-summary.json")
            let ledgerFile = root.appendingPathComponent("ledger.jsonl")
            var summary: [String: Any] = [
                "ledgerGeneration": scenario.generation, "rows": 1, "timezone": "UTC",
                "latestRecordedDate": "2026-07-13", "latestByHost": [],
                "monthToDate": ["totalCostUSD": 9999, "byHost": []],
                "today": ["totalCostUSD": 9999, "byHost": [], "unavailableHosts": []],
            ]
            if let schema = scenario.schema { summary["ledgerSchemaVersion"] = schema }
            try JSONSerialization.data(withJSONObject: summary).write(to: summaryFile)
            try #"{"ledgerGeneration":"generation-a","date":"2026-07-13","host":"local","costUSD":9999}"#
                .write(to: ledgerFile, atomically: true, encoding: .utf8)

            let snapshot = try XCTUnwrap(CodexUsageSnapshot.load(summaryFile: summaryFile, ledgerFile: ledgerFile))
            XCTAssertFalse(snapshot.isEstimateAvailable, scenario.message)
            XCTAssertEqual([snapshot.totalRow.allTime, snapshot.totalRow.monthToDate, snapshot.totalRow.today], ["—", "—", "—"])
            XCTAssertEqual(snapshot.availabilityMessageText, scenario.message)
            XCTAssertEqual(snapshot.menuBarBadgeText, "TinkerBar")
            XCTAssertEqual(snapshot.todayMenuBarBadgeText, "TinkerBar")
            if scenario.schema == nil {
                XCTAssertTrue(snapshot.estimateNoticeText.contains("rebuild is required"))
            }
        }
    }

    func testMalformedOptionalOfficialUsageDoesNotHideValidEstimate() throws {
        let root = try makeTemporaryDirectory(prefix: "TinkerBarOfficialUsageDecodeTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let summaryFile = root.appendingPathComponent("latest-summary.json")
        let ledgerFile = root.appendingPathComponent("ledger.jsonl")

        try #"{"ledgerSchemaVersion":2,"ledgerGeneration":"generation-a","rows":1,"timezone":"UTC","collector":{"version":"20.0.20","speed":"standard"},"models":{"observedRecent":["gpt-5.6-sol"],"catalogAvailable":true,"notInCurrentCatalog":[],"fallbackAttributed":[],"possiblyUnpricedRows":[]},"official":{"probeWarning":42,"accountUsage":{"available":true,"dailyUsageBuckets":[{"startDate":42,"tokens":"bad"}]}},"latestRecordedDate":"2026-07-13","collection":{"expectedHosts":["local"],"historicalFailedHosts":[]},"monthToDate":{"totalCostUSD":1.25,"byHost":[{"host":"local","totalCostUSD":1.25}]},"latestByHost":[{"host":"local","costUSD":1.25}],"yesterday":{"totalCostUSD":1.25,"byHost":[{"host":"local","costUSD":1.25}]},"today":{"totalCostUSD":0,"byHost":[],"unavailableHosts":[]}}"#.write(
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

    private func makeLedgerFixture(
        collectorScript: String
    ) throws -> (root: URL, task: AutomationTaskState, collector: URL) {
        guard ["jq", "perl"].allSatisfy({ executable(named: $0) != nil }) else {
            throw XCTSkip("Codex usage worker requires jq and perl")
        }
        let root = try makeTemporaryDirectory(prefix: "TinkerBarLedgerTests")
        let task = try XCTUnwrap(TaskCatalog(appSupportDirectory: root).discoverTasks().tasks.first {
            $0.id == "codex-usage-ledger"
        })
        let collector = root.appendingPathComponent("fake-ccusage")
        try collectorScript.write(to: collector, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: collector.path)
        return (root, task, collector)
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
    func testRuntimeCancellationStopsWorkerAndReturnsTaskToIdle() async throws {
        let fixture = try makeTaskFixture(script: sleepingWorkerScript, status: staleWorkerStatus)
        var childPID: pid_t?
        defer {
            if let childPID, processExists(childPID) { _ = Darwin.kill(childPID, SIGKILL) }
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: fixture.root, installsBuiltInTasks: false),
            runner: TaskRunner(executionTimeout: 5),
            autoload: false,
            loadStartupState: false
        )
        runtime.reloadTasks()
        runtime.runTaskNow(fixture.task.id)
        do {
            let childFile = fixture.task.paths.taskDirectory.appendingPathComponent("child.pid")
            let started = await waitUntilOnMainActor(timeout: 2) {
                runtime.tasks.first?.isRunning == true && FileManager.default.fileExists(atPath: childFile.path)
            }
            XCTAssertTrue(started, "Real worker did not start")
            let processID = try readChildPID(from: fixture.task.paths.taskDirectory)
            childPID = processID
            runtime.cancelTaskRun(fixture.task.id)
            let stopped = await waitUntilOnMainActor(timeout: 2) {
                runtime.tasks.first?.isRunning == false
            }
            XCTAssertTrue(stopped)
            XCTAssertEqual(runtime.message, "Reliability Task stopped.")
            let snapshot = try XCTUnwrap(runtime.tasks.first?.snapshot)
            XCTAssertTrue(snapshot.lastError.contains("stopped before completion"))
            let persisted = try String(contentsOf: fixture.task.paths.statusFile, encoding: .utf8)
            XCTAssertTrue(persisted.contains("last_error\t\(snapshot.lastError)"), persisted)
            XCTAssertFalse(persisted.contains("last_error\tstale worker failure"), persisted)
            XCTAssertTrue(waitForProcessToExit(processID, timeout: 2), processDescription(processID))
        } catch {
            await runtime.cancelAllTaskRuns()
            throw error
        }
        await runtime.cancelAllTaskRuns()
    }
}

private struct TaskFixture {
    let root: URL
    let task: AutomationTaskState
}

private let sleepingWorkerScript = """
#!/bin/zsh
/bin/sleep 10 &
child_pid=$!
print -r -- "$child_pid" > "${0:h}/child.pid"
wait "$child_pid"
"""

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
    let taskDirectory = root.appendingPathComponent("tasks/reliability-task", isDirectory: true)
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
    try JSONEncoder().encode(configuration).write(to: paths.configFile)
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
