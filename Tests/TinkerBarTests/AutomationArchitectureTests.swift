import Foundation
import Combine
import XCTest
@testable import TinkerBar

final class TaskCatalogTests: XCTestCase {
    func testBuiltInTaskOrderingShowsUsageBeforeUpdate() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let catalog = TaskCatalog(appSupportDirectory: appSupportDirectory)
        let tasks = try catalog.discoverTasks().tasks

        XCTAssertEqual(tasks.map(\.id), ["codex-usage-ledger", "codex-update", "heic-to-jpeg", "parsec-macmini-mirror"])
    }

    func testDiscoversCustomTaskFolderAndCreatesStatusFile() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let taskDirectory = try writeTask(
            id: "sample-interval",
            name: "Sample Interval",
            triggerKind: .interval,
            appSupportDirectory: appSupportDirectory
        )

        let catalog = TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false)
        let tasks = try catalog.discoverTasks().tasks

        XCTAssertEqual(tasks.map(\.id), ["sample-interval"])
        XCTAssertEqual(tasks.first?.configuration.name, "Sample Interval")
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskDirectory.statusFile.path))
        XCTAssertTrue(tasks.first?.snapshot.filesInstalled == true)
    }

    func testSkipsInvalidTaskFolderWithoutFailingDiscovery() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        try writeTask(
            id: "sample-interval",
            name: "Sample Interval",
            triggerKind: .interval,
            appSupportDirectory: appSupportDirectory
        )

        let brokenDirectory = appSupportDirectory
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: brokenDirectory.appendingPathComponent("task.json"))

        let catalog = TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false)
        let discovery = try catalog.discoverTasks()

        XCTAssertEqual(discovery.tasks.map(\.id), ["sample-interval"])
        XCTAssertEqual(discovery.skippedFolders, ["broken"])
    }
}

final class TaskRunnerTests: XCTestCase {
    func testDirectoryWorkerReceivesDirectoryStatusAndLogArguments() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        let watchedDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: appSupportDirectory)
            try? FileManager.default.removeItem(at: watchedDirectory)
        }

        let paths = try writeTask(
            id: "photos",
            name: "Photos",
            triggerKind: .directory,
            directoryPath: watchedDirectory.path,
            appSupportDirectory: appSupportDirectory
        )
        let task = AutomationTaskState(
            configuration: try loadConfiguration(from: paths.configFile),
            paths: paths,
            snapshot: AutomationTaskSnapshot(),
            isEnabled: true,
            isRunning: false
        )
        let capture = CommandCapture()
        let runner = TaskRunner(commandExecutor: capture.execute)

        try runner.run(task)

        let call = try XCTUnwrap(capture.calls.first)
        XCTAssertEqual(call.executable, "/bin/zsh")
        XCTAssertEqual(call.arguments, [
            paths.scriptFile.path,
            watchedDirectory.path,
            paths.statusFile.path,
            paths.logFile.path,
        ])
    }

    func testApplicationWorkerReceivesEventStatusAndLogArguments() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let paths = try writeTask(
            id: "parsec",
            name: "Parsec",
            triggerKind: .application,
            appSupportDirectory: appSupportDirectory,
            applicationName: "Parsec",
            bundleIdentifier: "tv.parsec.www"
        )
        let task = AutomationTaskState(
            configuration: try loadConfiguration(from: paths.configFile),
            paths: paths,
            snapshot: AutomationTaskSnapshot(),
            isEnabled: true,
            isRunning: false
        )
        let capture = CommandCapture()
        let runner = TaskRunner(commandExecutor: capture.execute)

        try runner.run(task, event: .opened)

        let call = try XCTUnwrap(capture.calls.first)
        XCTAssertEqual(call.executable, "/bin/zsh")
        XCTAssertEqual(call.arguments, [
            paths.scriptFile.path,
            "opened",
            paths.statusFile.path,
            paths.logFile.path,
        ])
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
    func testQuietHoursSuppressIntervalRuns() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        try writeTask(
            id: "usage",
            name: "Usage",
            triggerKind: .interval,
            intervalSeconds: 60,
            appSupportDirectory: appSupportDirectory
        )

        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(true, taskID: "usage")

        let calendar = makeUTCCalendar()
        let capture = CommandCapture()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: capture.execute),
            enablementStore: enablementStore,
            quietHours: AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar),
            dateProvider: { makeDate(hour: 2, calendar: calendar) },
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        runtime.requestTaskRun("usage", source: .interval)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(capture.calls.count, 0)
        runtime.toggleTask("usage")
    }

    @MainActor
    func testQuietHoursSuppressDirectoryLaunchRuns() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        let watchedDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: appSupportDirectory)
            try? FileManager.default.removeItem(at: watchedDirectory)
        }

        try writeTask(
            id: "photos",
            name: "Photos",
            triggerKind: .directory,
            directoryPath: watchedDirectory.path,
            appSupportDirectory: appSupportDirectory
        )

        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(true, taskID: "photos")

        let calendar = makeUTCCalendar()
        let capture = CommandCapture()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: capture.execute),
            enablementStore: enablementStore,
            quietHours: AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar),
            dateProvider: { makeDate(hour: 2, calendar: calendar) },
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(capture.calls.count, 0)
        runtime.toggleTask("photos")
    }

    @MainActor
    func testManualRunsBypassQuietHours() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        try writeTask(
            id: "usage",
            name: "Usage",
            triggerKind: .interval,
            intervalSeconds: 60,
            appSupportDirectory: appSupportDirectory
        )

        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(true, taskID: "usage")

        let calendar = makeUTCCalendar()
        let executor = BlockingCommandExecutor()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: executor.execute),
            enablementStore: enablementStore,
            quietHours: AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar),
            dateProvider: { makeDate(hour: 2, calendar: calendar) },
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        runtime.runTaskNow("usage")
        let sawRun = await executor.waitForCallCount(1)
        XCTAssertTrue(sawRun)

        runtime.toggleTask("usage")
        executor.unblockFirstCall()
        let becameIdle = await executor.waitUntilIdle()
        XCTAssertTrue(becameIdle)
    }

    @MainActor
    func testApplicationEventsBypassQuietHours() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        try writeTask(
            id: "parsec",
            name: "Parsec",
            triggerKind: .application,
            appSupportDirectory: appSupportDirectory,
            applicationName: "Parsec",
            bundleIdentifier: "tv.parsec.www"
        )

        let calendar = makeUTCCalendar()
        let capture = CommandCapture()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: capture.execute),
            quietHours: AutomationQuietHours(startHour: 1, endHour: 8, calendar: calendar),
            dateProvider: { makeDate(hour: 2, calendar: calendar) },
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        runtime.requestTaskRun("parsec", source: .application(.opened))

        let sawRun = await capture.waitForCallCount(1)
        XCTAssertTrue(sawRun)
        XCTAssertEqual(capture.calls.first?.arguments.dropFirst().first, "opened")
    }

    @MainActor
    func testIntervalTaskRunsAfterConfiguredDelay() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        try writeTask(
            id: "usage",
            name: "Usage",
            triggerKind: .interval,
            intervalSeconds: 0.05,
            appSupportDirectory: appSupportDirectory
        )

        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(true, taskID: "usage")

        let executor = BlockingCommandExecutor()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: executor.execute),
            enablementStore: enablementStore,
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        let sawRun = await executor.waitForCallCount(1)
        XCTAssertTrue(sawRun)

        runtime.toggleTask("usage")
        executor.unblockFirstCall()
        let becameIdle = await executor.waitUntilIdle()
        XCTAssertTrue(becameIdle)
    }

    @MainActor
    func testIntervalTaskRunsImmediatelyWhenOverdue() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let paths = try writeTask(
            id: "usage",
            name: "Usage",
            triggerKind: .interval,
            intervalSeconds: 60,
            appSupportDirectory: appSupportDirectory
        )
        try writeStatus(lastRun: Date(timeIntervalSinceNow: -120), to: paths.statusFile)

        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(true, taskID: "usage")

        let executor = BlockingCommandExecutor()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: executor.execute),
            enablementStore: enablementStore,
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        let sawRun = await executor.waitForCallCount(1)
        XCTAssertTrue(sawRun)

        runtime.toggleTask("usage")
        executor.unblockFirstCall()
        let becameIdle = await executor.waitUntilIdle()
        XCTAssertTrue(becameIdle)
    }

    @MainActor
    func testDirectoryTriggersCoalesceOneFollowUpWhileRunning() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        let watchedDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: appSupportDirectory)
            try? FileManager.default.removeItem(at: watchedDirectory)
        }

        try writeTask(
            id: "photos",
            name: "Photos",
            triggerKind: .directory,
            directoryPath: watchedDirectory.path,
            appSupportDirectory: appSupportDirectory
        )

        let suiteName = "TinkerBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enablementStore = TaskEnablementStore(defaults: defaults)
        enablementStore.setEnabled(true, taskID: "photos")

        let executor = BlockingCommandExecutor()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            runner: TaskRunner(commandExecutor: executor.execute),
            enablementStore: enablementStore,
            autoload: false,
            loadStartupState: false
        )

        runtime.reloadTasks()
        XCTAssertEqual(runtime.tasks.map(\.id), ["photos"])

        runtime.requestTaskRun("photos", source: .directory)
        let sawFirstRun = await executor.waitForCallCount(1)
        XCTAssertTrue(sawFirstRun)
        XCTAssertTrue(runtime.tasks.first?.isRunning == true)

        runtime.requestTaskRun("photos", source: .directory)
        runtime.requestTaskRun("photos", source: .directory)
        XCTAssertEqual(executor.callCount, 1)

        executor.unblockFirstCall()
        let sawCoalescedRun = await executor.waitForCallCount(2)
        XCTAssertTrue(sawCoalescedRun)
        let becameIdle = await executor.waitUntilIdle()
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(executor.callCount, 2)
        XCTAssertTrue(runtime.tasks.first?.isRunning == false)

        runtime.toggleTask("photos")
    }

    @MainActor
    func testRefreshPublishesTaskSnapshotChanges() throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        let paths = try writeTask(
            id: "usage",
            name: "Usage",
            triggerKind: .interval,
            intervalSeconds: 60,
            appSupportDirectory: appSupportDirectory
        )

        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            autoload: false,
            loadStartupState: false
        )
        runtime.reloadTasks()

        let expectedLastRun = "2026-04-30T06:44:10Z"
        try writeStatus(lastRunISO: expectedLastRun, to: paths.statusFile)

        let publishExpectation = expectation(description: "refresh publishes task snapshot changes")
        var cancellables = Set<AnyCancellable>()
        runtime.objectWillChange
            .sink {
                publishExpectation.fulfill()
            }
            .store(in: &cancellables)

        runtime.refresh()

        wait(for: [publishExpectation], timeout: 1)
        XCTAssertEqual(runtime.tasks.first?.snapshot.lastRunISO, expectedLastRun)
    }

    @MainActor
    func testRefreshIgnoresOlderResultsThatCompleteLate() async throws {
        let appSupportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupportDirectory) }

        try writeTask(
            id: "usage",
            name: "Usage",
            triggerKind: .interval,
            intervalSeconds: 60,
            appSupportDirectory: appSupportDirectory
        )

        let loader = OrderedSnapshotLoader()
        let runtime = AutomationRuntime(
            catalog: TaskCatalog(appSupportDirectory: appSupportDirectory, installsBuiltInTasks: false),
            snapshotLoader: loader.snapshot,
            autoload: false,
            loadStartupState: false
        )
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
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(runtime.tasks.first?.snapshot.lastRunISO, "newer-refresh")
    }
}

private struct CommandCall: Sendable {
    let executable: String
    let arguments: [String]
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [CommandCall] = []

    var calls: [CommandCall] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func execute(_ executable: String, _ arguments: [String]) -> CommandResult {
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
    private var currentCallCount = 0
    private var firstCallIsUnblocked = false
    private var activeCalls = 0

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentCallCount
    }

    func execute(_ executable: String, _ arguments: [String]) -> CommandResult {
        condition.lock()
        currentCallCount += 1
        activeCalls += 1
        let callNumber = currentCallCount
        condition.broadcast()

        while callNumber == 1 && !firstCallIsUnblocked {
            condition.wait()
        }

        activeCalls -= 1
        condition.broadcast()
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
        await waitUntil(timeout: timeout) {
            self.callCount >= expectedCount
        }
    }

    func waitUntilIdle(timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) {
            self.condition.lock()
            let isIdle = self.activeCalls == 0
            self.condition.unlock()
            return isIdle
        }
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
