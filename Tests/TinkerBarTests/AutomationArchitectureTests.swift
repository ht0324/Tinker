import Foundation
import Combine
import Darwin
import XCTest
@testable import TinkerBar

final class TaskCatalogTests: XCTestCase {
    func testBuiltInTasksInstallAndRefreshInDisplayOrder() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let catalog = TaskCatalog(appSupportDirectory: appSupportDirectory)
        let tasks = try catalog.discoverTasks().tasks

        XCTAssertEqual(tasks.map(\.id), ["codex-usage-ledger", "codex-update", "heic-to-jpeg", "parsec-macmini-mirror"])
        XCTAssertTrue(tasks.allSatisfy { $0.snapshot.filesInstalled })

        let paths = try XCTUnwrap(tasks.first(where: { $0.id == "codex-update" })?.paths)
        let bundledScript = try String(contentsOf: paths.scriptFile, encoding: .utf8)
        try "outdated worker".write(to: paths.scriptFile, atomically: true, encoding: .utf8)

        _ = try catalog.discoverTasks()
        XCTAssertEqual(try String(contentsOf: paths.scriptFile, encoding: .utf8), bundledScript)
    }

    func testUsageWorkerInstallsItsHelperForACustomTaskID() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let paths = try writeTask(
            id: "custom-usage", name: "Custom Usage", triggerKind: .interval,
            appSupportDirectory: appSupportDirectory
        )
        var configuration = try loadConfiguration(from: paths.configFile)
        configuration.scriptKind = "codex_usage_ledger"
        try JSONEncoder().encode(configuration).write(to: paths.configFile)

        let tasks = try TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false)
            .discoverTasks().tasks
        XCTAssertEqual(tasks.map(\.id), ["custom-usage"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.taskDirectory.appendingPathComponent("codex-usage-app-server.mjs").path
        ))
    }

    func testDiscoveryPreservesCustomConfigurationWorkerAndStatus() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }
        let paths = try writeTask(
            id: "codex-usage-ledger", name: "Custom Usage", triggerKind: .interval,
            appSupportDirectory: appSupportDirectory
        )
        var configuration = try loadConfiguration(from: paths.configFile)
        configuration.detail = "Track Codex spend for my custom worker."
        try JSONEncoder().encode(configuration).write(to: paths.configFile)
        let originalConfiguration = try Data(contentsOf: paths.configFile)
        let originalWorker = try Data(contentsOf: paths.scriptFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.scriptFile.path)

        let catalog = TaskCatalog(appSupportDirectory: appSupportDirectory)
        let task = try XCTUnwrap(catalog.discoverTasks().tasks.first { $0.id == "codex-usage-ledger" })
        XCTAssertNil(task.configuration.scriptKind)
        XCTAssertEqual(task.configuration.name, "Custom Usage")
        XCTAssertTrue(task.snapshot.filesInstalled)
        XCTAssertEqual(
            try String(contentsOf: paths.statusFile, encoding: .utf8),
            "last_run_iso\t\nlast_success_iso\t\nsuccess_count\t0\nlast_output\t\nlast_error\t\n"
        )
        guard case .success = TaskRunner().run(task) else {
            return XCTFail("Readable workers must run without execute permission")
        }

        let customStatus = "last_output\tKeep this status\ncustom_field\tkeep me too\n"
        try customStatus.write(to: paths.statusFile, atomically: true, encoding: .utf8)
        _ = try catalog.discoverTasks()
        XCTAssertEqual(try Data(contentsOf: paths.configFile), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: paths.scriptFile), originalWorker)
        XCTAssertEqual(try String(contentsOf: paths.statusFile, encoding: .utf8), customStatus)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.taskDirectory.appendingPathComponent("codex-usage-app-server.mjs").path
        ))
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.scriptFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testMalformedBuiltInTaskDoesNotPreventOtherTasksFromLoading() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let brokenDirectory = appSupportDirectory
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("codex-usage-ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: brokenDirectory.appendingPathComponent("task.json")
        )

        let discovery = try TaskCatalog(appSupportDirectory: appSupportDirectory).discoverTasks()

        XCTAssertEqual(
            discovery.tasks.map(\.id),
            ["codex-update", "heic-to-jpeg", "parsec-macmini-mirror"]
        )
        XCTAssertEqual(discovery.skippedFolders, ["codex-usage-ledger"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenDirectory.appendingPathComponent("run.sh").path))
    }
}

final class DirectoryMonitorTests: XCTestCase {
    func testMonitorNotifiesForNewAndRenamedRegularFilesOnly() async throws {
        let watchedDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: watchedDirectory) }

        let existingFile = watchedDirectory.appendingPathComponent("existing.crdownload")
        try Data("old".utf8).write(to: existingFile)

        let counter = EventCounter()
        let monitor = DirectoryMonitor(url: watchedDirectory) {
            counter.increment()
        }
        try monitor.start()
        defer { monitor.stop() }

        let renamedFile = watchedDirectory.appendingPathComponent("renamed.heic")
        try FileManager.default.moveItem(at: existingFile, to: renamedFile)
        let sawRenameEvent = await waitUntil(timeout: 2) {
            counter.count == 1
        }
        XCTAssertTrue(sawRenameEvent)

        let createdDirectory = watchedDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: createdDirectory, withIntermediateDirectories: true)
        let sawDirectoryEvent = await waitUntil(timeout: 0.4) {
            counter.count > 1
        }
        XCTAssertFalse(sawDirectoryEvent)

        let createdFile = watchedDirectory.appendingPathComponent("created.heic")
        try Data("new".utf8).write(to: createdFile)
        let sawCreateEvent = await waitUntil(timeout: 2) {
            counter.count == 2
        }
        XCTAssertTrue(sawCreateEvent)
    }
}

final class AutomationQuietHoursTests: XCTestCase {
    func testQuietHoursCoverOneAMUntilEightAM() {
        let calendar = makeUTCCalendar()
        let quietHours = AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar)

        XCTAssertFalse(quietHours.contains(makeDate(hour: 0, minute: 59, calendar: calendar)))
        XCTAssertTrue(quietHours.contains(makeDate(hour: 1, calendar: calendar)))
        XCTAssertTrue(quietHours.contains(makeDate(hour: 7, minute: 59, calendar: calendar)))
        XCTAssertFalse(quietHours.contains(makeDate(hour: 8, calendar: calendar)))
    }
}

final class AutomationRuntimeTests: XCTestCase {
    @MainActor
    func testInvalidIntervalsCannotEnableScheduling() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }
        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enablementStore = TaskEnablementStore(defaults: defaults)

        for (index, interval) in ([nil, 0, -1, 1e100] as [Double?]).enumerated() {
            let id = "invalid-\(index)"
            try writeTask(
                id: id, name: id, triggerKind: .interval, intervalSeconds: interval,
                appSupportDirectory: appSupportDirectory
            )
            enablementStore.setEnabled(true, taskID: id)
        }

        let capture = CommandCapture()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: capture.execute),
            enablementStore: enablementStore,
            quietHours: AutomationQuietHours(startHour: 0, endHour: 0),
            loadStartupState: false
        )

        XCTAssertEqual(runtime.tasks.count, 4)
        for task in runtime.tasks {
            XCTAssertFalse(task.isEnabled)
            XCTAssertFalse(enablementStore.isEnabled(task.id))
            XCTAssertEqual(task.configuration.triggerDetail, "No valid interval configured")
            runtime.toggleTask(task.id)
            XCTAssertFalse(try XCTUnwrap(runtime.tasks.first(where: { $0.id == task.id })).isEnabled)
            XCTAssertFalse(enablementStore.isEnabled(task.id))
            XCTAssertTrue(runtime.message.contains("intervalSeconds"))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(capture.calls.isEmpty)
    }

    @MainActor
    func testQuietHoursSuppressAutomaticRunsButAllowManualRuns() async throws {
        let calendar = makeUTCCalendar()
        let capture = CommandCapture()
        let fixture = try makeRuntimeFixture(
            enabled: true,
            runner: TaskRunner(commandExecutor: capture.execute),
            quietHours: AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar),
            dateProvider: { makeDate(hour: 2, calendar: calendar) }
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        runtime.requestTaskRun("usage", source: .interval)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(capture.calls.isEmpty)

        runtime.runTaskNow("usage")
        let sawRun = await capture.waitForCallCount(1)
        XCTAssertTrue(sawRun)
        let call = try XCTUnwrap(capture.calls.first)
        XCTAssertEqual(call.executable, "/bin/zsh")
        XCTAssertEqual(normalizedArguments(call.arguments), normalizedArguments([
            fixture.paths.scriptFile.path, fixture.paths.statusFile.path, fixture.paths.logFile.path,
        ]))
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
        XCTAssertEqual(capture.calls.count, 1)
    }

    @MainActor
    func testApplicationEventsBypassQuietHours() async throws {
        let calendar = makeUTCCalendar()
        let capture = CommandCapture()
        let fixture = try makeRuntimeFixture(
            id: "parsec", triggerKind: .application,
            runner: TaskRunner(commandExecutor: capture.execute),
            quietHours: AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar),
            dateProvider: { makeDate(hour: 2, calendar: calendar) }
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        runtime.requestTaskRun("parsec", source: .application(.opened))
        let sawRun = await capture.waitForCallCount(1)
        XCTAssertTrue(sawRun)
        let call = try XCTUnwrap(capture.calls.first)
        XCTAssertEqual(call.executable, "/bin/zsh")
        XCTAssertEqual(normalizedArguments(call.arguments), normalizedArguments([
            fixture.paths.scriptFile.path, "opened", fixture.paths.statusFile.path, fixture.paths.logFile.path,
        ]))
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
        XCTAssertEqual(runtime.tasks.first?.snapshot.lastError, "")
    }

    @MainActor
    func testIntervalTimerStartsWorkerAfterDelay() async throws {
        let executor = BlockingCommandExecutor()
        defer { executor.unblockFirstCall() }
        let fixture = try makeRuntimeFixture(
            intervalSeconds: 1, enabled: true,
            runner: TaskRunner(commandExecutor: executor.execute)
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        XCTAssertFalse(try XCTUnwrap(runtime.tasks.first).isRunning)
        let sawRun = await executor.waitForCallCount(1, timeout: 7)
        XCTAssertTrue(sawRun)

        runtime.toggleTask("usage")
        executor.unblockFirstCall()
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
    }

    @MainActor
    func testIntervalTaskRunsImmediatelyWhenOverdue() async throws {
        let now = makeDate(hour: 12, calendar: makeUTCCalendar())
        let executor = BlockingCommandExecutor()
        defer { executor.unblockFirstCall() }
        let fixture = try makeRuntimeFixture(
            enabled: true, lastRun: now.addingTimeInterval(-120),
            runner: TaskRunner(commandExecutor: executor.execute), dateProvider: { now }
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        XCTAssertTrue(try XCTUnwrap(runtime.tasks.first).isRunning)
        let sawRun = await executor.waitForCallCount(1)
        XCTAssertTrue(sawRun)

        runtime.toggleTask("usage")
        executor.unblockFirstCall()
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
    }

    @MainActor
    func testRecentIntervalRunWaitsOnReloadButRunsWhenEnabledManually() async throws {
        let now = makeDate(hour: 12, calendar: makeUTCCalendar())
        let capture = CommandCapture()
        let fixture = try makeRuntimeFixture(
            enabled: true, lastRun: now,
            runner: TaskRunner(commandExecutor: capture.execute), dateProvider: { now }
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        XCTAssertFalse(try XCTUnwrap(runtime.tasks.first).isRunning)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(capture.calls.isEmpty)

        runtime.toggleTask("usage")
        runtime.toggleTask("usage")
        let sawRun = await capture.waitForCallCount(1)
        XCTAssertTrue(sawRun)
        runtime.toggleTask("usage")
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
    }

    @MainActor
    func testRunningDirectoryTaskSurvivesReloadAndCoalescesOneFollowUp() async throws {
        let executor = BlockingCommandExecutor()
        defer { executor.unblockFirstCall() }
        let fixture = try makeRuntimeFixture(
            id: "photos", triggerKind: .directory, enabled: true,
            runner: TaskRunner(commandExecutor: executor.execute)
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        runtime.requestTaskRun("photos", source: .directory)
        let sawFirstRun = await executor.waitForCallCount(1)
        XCTAssertTrue(sawFirstRun)
        let call = try XCTUnwrap(executor.calls.first)
        XCTAssertEqual(call.executable, "/bin/zsh")
        XCTAssertEqual(normalizedArguments(call.arguments), normalizedArguments([
            fixture.paths.scriptFile.path, fixture.watchedDirectory.path,
            fixture.paths.statusFile.path, fixture.paths.logFile.path,
        ]))

        runtime.reloadTasks()
        XCTAssertTrue(try XCTUnwrap(runtime.tasks.first).isRunning)
        runtime.requestTaskRun("photos", source: .directory)
        runtime.requestTaskRun("photos", source: .directory)
        XCTAssertEqual(executor.callCount, 1)

        executor.unblockFirstCall()
        let sawCoalescedRun = await executor.waitForCallCount(2)
        XCTAssertTrue(sawCoalescedRun)
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
        XCTAssertEqual(runtime.tasks.first?.snapshot.lastError, "")
        XCTAssertEqual(executor.callCount, 2)
    }

    @MainActor
    func testDisablingTaskDropsCoalescedDirectoryRun() async throws {
        let executor = BlockingCommandExecutor()
        defer { executor.unblockFirstCall() }
        let fixture = try makeRuntimeFixture(
            id: "photos", triggerKind: .directory, enabled: true,
            runner: TaskRunner(commandExecutor: executor.execute)
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        runtime.requestTaskRun("photos", source: .directory)
        let started = await executor.waitForCallCount(1)
        XCTAssertTrue(started)
        runtime.requestTaskRun("photos", source: .directory)
        runtime.toggleTask("photos")
        executor.unblockFirstCall()
        let finished = await waitUntilOnMainActor(timeout: 2) { runtime.tasks.first?.isRunning == false }
        XCTAssertTrue(finished)
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertFalse(try XCTUnwrap(runtime.tasks.first).isEnabled)
    }

    @MainActor
    func testQueuedDirectoryCallbackDoesNotRunAfterDisable() async throws {
        let capture = CommandCapture()
        let fixture = try makeRuntimeFixture(
            id: "photos", triggerKind: .directory, enabled: true,
            runner: TaskRunner(commandExecutor: capture.execute)
        )
        let runtime = fixture.runtime
        runtime.reloadTasks()
        try Data("queued".utf8).write(to: fixture.watchedDirectory.appendingPathComponent("queued.heic"))

        // Let the monitor queue enqueue a callback while the main actor is busy,
        // then invalidate its registration before the callback can resume.
        usleep(1_000_000)
        runtime.toggleTask("photos")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertFalse(try XCTUnwrap(runtime.tasks.first).isEnabled)
    }

    @MainActor
    func testRefreshPublishesTaskSnapshotChanges() throws {
        let fixture = try makeRuntimeFixture()
        let runtime = fixture.runtime
        runtime.reloadTasks()
        let expectedLastRun = "2026-04-30T06:44:10Z"
        try writeStatus(lastRunISO: expectedLastRun, to: fixture.paths.statusFile)

        let publishExpectation = expectation(description: "refresh publishes task snapshot changes")
        var cancellables = Set<AnyCancellable>()
        runtime.objectWillChange
            .sink { publishExpectation.fulfill() }
            .store(in: &cancellables)
        runtime.refresh()
        wait(for: [publishExpectation], timeout: 1)
        XCTAssertEqual(runtime.tasks.first?.snapshot.lastRunISO, expectedLastRun)
    }

    @MainActor
    func testRefreshIgnoresOlderResultsThatCompleteLate() async throws {
        let loader = OrderedSnapshotLoader()
        defer { loader.unblockFirstCall() }
        let fixture = try makeRuntimeFixture(snapshotLoader: loader.snapshot)
        let runtime = fixture.runtime
        runtime.reloadTasks()
        runtime.refresh()
        let sawFirstRefresh = await loader.waitForCallCount(1)
        XCTAssertTrue(sawFirstRefresh)

        runtime.refresh()
        let sawSecondRefresh = await loader.waitForCallCount(2)
        XCTAssertTrue(sawSecondRefresh)
        let appliedSecondRefresh = await waitUntilOnMainActor(timeout: 1) {
            runtime.tasks.first?.snapshot.lastRunISO == "newer-refresh"
        }
        XCTAssertTrue(appliedSecondRefresh)

        loader.unblockFirstCall()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.tasks.first?.snapshot.lastRunISO, "newer-refresh")
    }

    @MainActor
    private func makeRuntimeFixture(
        id: String = "usage",
        triggerKind: AutomationTriggerKind = .interval,
        intervalSeconds: Double? = 60,
        enabled: Bool = false,
        lastRun: Date? = nil,
        runner: TaskRunner = TaskRunner(),
        quietHours: AutomationQuietHours = AutomationQuietHours(startHour: 0, endHour: 0),
        dateProvider: @escaping () -> Date = Date.init,
        snapshotLoader: @escaping @Sendable (AutomationTaskPaths) -> AutomationTaskSnapshot = {
            TaskStatusStore.snapshot(for: $0)
        }
    ) throws -> (runtime: AutomationRuntime, paths: AutomationTaskPaths, watchedDirectory: URL) {
        let root = try makeTemporaryDirectory()
        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let watchedDirectory = root.appendingPathComponent("watched", isDirectory: true)
        if triggerKind == .directory {
            try FileManager.default.createDirectory(at: watchedDirectory, withIntermediateDirectories: true)
        }
        let paths = try writeTask(
            id: id, name: id, triggerKind: triggerKind,
            directoryPath: triggerKind == .directory ? watchedDirectory.path : nil,
            intervalSeconds: intervalSeconds, appSupportDirectory: root,
            applicationName: triggerKind == .application ? "Parsec" : nil,
            bundleIdentifier: triggerKind == .application ? "tv.parsec.www" : nil
        )
        if let lastRun { try writeStatus(lastRun: lastRun, to: paths.statusFile) }
        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(enabled, taskID: id)
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: root, installsBuiltInTasks: false),
            runner: runner, enablementStore: enablementStore, quietHours: quietHours,
            dateProvider: dateProvider, snapshotLoader: snapshotLoader,
            autoload: false, loadStartupState: false
        )
        addTeardownBlock { @MainActor in
            for task in runtime.tasks where task.isEnabled { runtime.toggleTask(task.id) }
            await runtime.cancelAllTaskRuns()
        }
        return (runtime, paths, watchedDirectory)
    }
}

private struct CommandCall: Sendable {
    let executable: String
    let arguments: [String]
}

private func normalizedArguments(_ arguments: [String]) -> [String] {
    arguments.map {
        guard $0.hasPrefix("/") else { return $0 }
        let url = URL(fileURLWithPath: $0)
        // Resolve the existing parent because the worker may not have created task.log yet.
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [CommandCall] = []

    var calls: [CommandCall] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func execute(
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> CommandResult {
        lock.lock()
        recordedCalls.append(CommandCall(executable: executable, arguments: arguments))
        lock.unlock()
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func waitForCallCount(_ expectedCount: Int, timeout: TimeInterval = 1) async -> Bool {
        await waitUntil(timeout: timeout) {
            self.calls.count >= expectedCount
        }
    }
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class BlockingCommandExecutor: @unchecked Sendable {
    private let condition = NSCondition()
    private var recordedCalls: [CommandCall] = []
    private var firstCallIsUnblocked = false

    var calls: [CommandCall] {
        condition.lock()
        defer { condition.unlock() }
        return recordedCalls
    }

    var callCount: Int { calls.count }

    func execute(
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> CommandResult {
        condition.lock()
        recordedCalls.append(CommandCall(executable: executable, arguments: arguments))
        let callNumber = recordedCalls.count
        while callNumber == 1 && !firstCallIsUnblocked { condition.wait() }
        condition.unlock()
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func unblockFirstCall() {
        condition.lock()
        firstCallIsUnblocked = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForCallCount(_ expectedCount: Int, timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) { self.callCount >= expectedCount }
    }
}

private final class OrderedSnapshotLoader: @unchecked Sendable {
    private let condition = NSCondition()
    private var currentCallCount = 0
    private var firstCallIsUnblocked = false

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentCallCount
    }

    func snapshot(for paths: AutomationTaskPaths) -> AutomationTaskSnapshot {
        condition.lock()
        currentCallCount += 1
        let callNumber = currentCallCount
        condition.broadcast()

        while callNumber == 1 && !firstCallIsUnblocked {
            condition.wait()
        }

        condition.unlock()

        var snapshot = AutomationTaskSnapshot()
        snapshot.filesInstalled = true
        snapshot.lastRunISO = callNumber == 1 ? "older-refresh" : "newer-refresh"
        return snapshot
    }

    func unblockFirstCall() {
        condition.lock()
        firstCallIsUnblocked = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForCallCount(_ expectedCount: Int, timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) {
            self.callCount >= expectedCount
        }
    }
}

private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return condition()
}

@MainActor
private func waitUntilOnMainActor(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return condition()
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TinkerBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}

private func makeDate(hour: Int, minute: Int = 0, calendar: Calendar) -> Date {
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = 2026
    components.month = 4
    components.day = 30
    components.hour = hour
    components.minute = minute
    return components.date ?? Date(timeIntervalSince1970: 0)
}

@discardableResult
private func writeTask(
    id: String,
    name: String,
    triggerKind: AutomationTriggerKind,
    directoryPath: String? = nil,
    intervalSeconds: Double? = 60,
    appSupportDirectory: URL,
    applicationName: String? = nil,
    bundleIdentifier: String? = nil
) throws -> AutomationTaskPaths {
    let taskDirectory = appSupportDirectory
        .appendingPathComponent("tasks", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    let paths = AutomationTaskPaths(taskDirectory: taskDirectory)
    try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)

    let configuration = AutomationTaskConfiguration(
        id: id,
        name: name,
        detail: "Test task",
        scriptKind: nil,
        triggerKind: triggerKind,
        directoryPath: directoryPath,
        intervalSeconds: triggerKind == .interval ? intervalSeconds : nil,
        openPath: nil,
        applicationName: applicationName,
        bundleIdentifier: bundleIdentifier
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(configuration).write(to: paths.configFile)
    try "#!/bin/zsh\nexit 0\n".write(to: paths.scriptFile, atomically: true, encoding: .utf8)
    return paths
}

private func writeStatus(lastRun: Date, to url: URL) throws {
    let formatter = ISO8601DateFormatter()
    try writeStatus(lastRunISO: formatter.string(from: lastRun), to: url)
}

private func writeStatus(lastRunISO: String, to url: URL) throws {
    let status = """
    last_run_iso\t\(lastRunISO)
    last_success_iso\t
    success_count\t0
    last_output\t
    last_error\t
    """
    try status.write(to: url, atomically: true, encoding: .utf8)
}

private func loadConfiguration(from url: URL) throws -> AutomationTaskConfiguration {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(AutomationTaskConfiguration.self, from: data)
}
