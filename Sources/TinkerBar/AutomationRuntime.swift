import Foundation
import Dispatch
import SwiftUI

enum AutomationError: LocalizedError {
    case invalidConfiguration(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

enum TaskRunRequestSource: Equatable, Sendable {
    case manual
    case directory
    case interval
    case application(ApplicationTriggerEvent)

    var isUserInitiated: Bool {
        switch self {
        case .manual:
            return true
        case .directory, .interval, .application:
            return false
        }
    }

    var defersForQuietHours: Bool {
        switch self {
        case .directory, .interval:
            return true
        case .manual, .application:
            return false
        }
    }

    var applicationEvent: ApplicationTriggerEvent? {
        switch self {
        case .application(let event):
            return event
        case .manual, .directory, .interval:
            return nil
        }
    }
}

struct AutomationQuietHours {
    static let overnight = AutomationQuietHours(startHour: 1, endHour: 8)

    let startHour: Int
    let endHour: Int
    var calendar: Calendar

    init(startHour: Int, endHour: Int, calendar: Calendar = .current) {
        self.startHour = startHour
        self.endHour = endHour
        self.calendar = calendar
    }

    func contains(_ date: Date) -> Bool {
        let hour = calendar.component(.hour, from: date)

        if startHour < endHour {
            return hour >= startHour && hour < endHour
        }

        if startHour > endHour {
            return hour >= startHour || hour < endHour
        }

        return false
    }

    func nextAllowedDate(after date: Date) -> Date {
        guard contains(date) else { return date }

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = endHour
        components.minute = 0
        components.second = 0
        components.nanosecond = 0

        guard let endToday = calendar.date(from: components) else { return date }
        if endToday > date {
            return endToday
        }

        return calendar.date(byAdding: .day, value: 1, to: endToday) ?? date
    }

    var rangeDescription: String {
        "\(formattedHour(startHour))-\(formattedHour(endHour))"
    }

    private func formattedHour(_ hour: Int) -> String {
        let normalizedHour = ((hour % 24) + 24) % 24
        if normalizedHour == 0 {
            return "12 AM"
        }
        if normalizedHour < 12 {
            return "\(normalizedHour) AM"
        }
        if normalizedHour == 12 {
            return "12 PM"
        }
        return "\(normalizedHour - 12) PM"
    }
}

@MainActor
final class AutomationRuntime: ObservableObject {
    @Published var tasks: [AutomationTaskState] = []
    @Published var isBusy = false
    @Published var launchAtLoginEnabled = false
    @Published var message = ""

    private let catalog: TaskCatalog
    private let runner: TaskRunner
    private let opener: TaskOpener
    private let startupController: StartupController
    private let enablementStore: TaskEnablementStore
    private let quietHours: AutomationQuietHours
    private let dateProvider: () -> Date
    private let snapshotLoader: @Sendable (AutomationTaskPaths) -> AutomationTaskSnapshot

    private var directoryMonitors: [String: DirectoryMonitor] = [:]
    private var applicationMonitors: [String: ApplicationMonitor] = [:]
    private var pendingRunTasks: [String: Task<Void, Never>] = [:]
    private var intervalTimers: [String: DispatchSourceTimer] = [:]
    private var quietHourDeferredRunTimers: [String: DispatchSourceTimer] = [:]
    private var runningTaskIDs: Set<String> = []
    private var coalescedRunSources: [String: TaskRunRequestSource] = [:]
    private var refreshGeneration = 0

    private let codexUsageTaskID = "codex-usage-ledger"

    init(
        catalog: TaskCatalog = TaskCatalog(),
        runner: TaskRunner = TaskRunner(),
        opener: TaskOpener? = nil,
        startupController: StartupController = StartupController(),
        enablementStore: TaskEnablementStore = TaskEnablementStore(),
        quietHours: AutomationQuietHours = .overnight,
        dateProvider: @escaping () -> Date = Date.init,
        snapshotLoader: @escaping @Sendable (AutomationTaskPaths) -> AutomationTaskSnapshot = { paths in
            TaskSnapshotLoader().snapshot(for: paths)
        },
        autoload: Bool = true,
        loadStartupState: Bool = true
    ) {
        self.catalog = catalog
        self.runner = runner
        self.opener = opener ?? TaskOpener(tasksDirectory: catalog.tasksDirectory)
        self.startupController = startupController
        self.enablementStore = enablementStore
        self.quietHours = quietHours
        self.dateProvider = dateProvider
        self.snapshotLoader = snapshotLoader

        if loadStartupState {
            launchAtLoginEnabled = startupController.isEnabled()
        }

        if autoload {
            loadTasks(using: .appLaunch)
        }
    }

    var summaryText: String {
        let enabledCount = tasks.filter(\.isEnabled).count
        if enabledCount == 0 {
            return "No automations enabled"
        }

        return enabledCount == 1 ? "1 automation enabled" : "\(enabledCount) automations enabled"
    }

    var hasEnabledTasks: Bool {
        tasks.contains(where: \.isEnabled)
    }

    var codexUsageSnapshot: CodexUsageSnapshot? {
        tasks.first(where: { $0.id == codexUsageTaskID })?.snapshot.codexUsage
    }

    func menuBarTitle(showingTodaySpending: Bool) -> String {
        if showingTodaySpending, let todayBadge = codexUsageSnapshot?.todayMenuBarBadgeText {
            return todayBadge
        }

        return codexUsageSnapshot?.menuBarBadgeText ?? "TinkerBar"
    }

    var quietModeStatusText: String {
        let now = dateProvider()
        if quietHours.contains(now) {
            return "Quiet mode active until \(formattedQuietHour(quietHours.nextAllowedDate(after: now)))"
        }

        return "Quiet mode active \(quietHours.rangeDescription)"
    }

    func reloadTasks() {
        loadTasks(using: .reload)
    }

    func refresh() {
        let identifiedPaths = tasks.map { (id: $0.id, paths: $0.paths) }
        guard !identifiedPaths.isEmpty else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshotLoader = snapshotLoader

        Task { [weak self] in
            let snapshots = await Task.detached(priority: .utility) {
                identifiedPaths.map { (id: $0.id, snapshot: snapshotLoader($0.paths)) }
            }.value

            guard let self else { return }
            guard self.refreshGeneration == generation else { return }

            // Apply by ID and publish once: a reload between dispatch and
            // completion may have changed the task list out from under us.
            let snapshotsByID = Dictionary(snapshots.map { ($0.id, $0.snapshot) }, uniquingKeysWith: { _, latest in latest })
            var updatedTasks = self.tasks
            var didChange = false
            for index in updatedTasks.indices {
                if let snapshot = snapshotsByID[updatedTasks[index].id] {
                    updatedTasks[index].snapshot = snapshot
                    didChange = true
                }
            }
            if didChange {
                self.tasks = updatedTasks
            }
        }
    }

    func menuDidAppear() {
        refresh()
    }

    func toggleTask(_ taskID: String) {
        guard let index = indexOfTask(taskID) else { return }

        if tasks[index].isEnabled {
            stopTaskScheduling(taskID)
            let task = updateTask(at: index) { task in
                task.isEnabled = false
            }
            enablementStore.setEnabled(false, taskID: taskID)
            message = "\(task.configuration.name) disabled."
            return
        }

        do {
            try startTask(taskID, using: .manualEnable)
            let task = updateTask(at: index) { task in
                task.isEnabled = true
            }
            enablementStore.setEnabled(true, taskID: taskID)
            message = "\(task.configuration.name) enabled."
        } catch {
            updateTask(at: index) { task in
                task.isEnabled = false
            }
            enablementStore.setEnabled(false, taskID: taskID)
            message = error.localizedDescription
        }
    }

    func runTaskNow(_ taskID: String) {
        requestTaskRun(taskID, source: .manual)
    }

    func requestTaskRun(_ taskID: String, source: TaskRunRequestSource) {
        guard let index = indexOfTask(taskID) else { return }

        if shouldDeferForQuietHours(source: source) {
            deferTaskRunUntilQuietHoursEnd(taskID, source: source)
            return
        }

        if tasks[index].isRunning {
            switch source {
            case .directory, .application:
                coalescedRunSources[taskID] = source
            case .manual, .interval:
                break
            }
            return
        }

        startTaskRun(taskID, source: source)
    }

    func openTasksFolder() {
        opener.openTasksDirectory()
    }

    func openTaskFolder(_ taskID: String) {
        guard let task = task(taskID) else { return }
        opener.openTaskFolder(task)
    }

    func openTaskLog(_ taskID: String) {
        guard let task = task(taskID) else { return }
        opener.openTaskLog(task)
    }

    func openTaskTarget(_ taskID: String) {
        guard let task = task(taskID) else { return }
        opener.openTaskTarget(task)
    }

    func toggleLaunchAtLogin() {
        isBusy = true
        let startupController = startupController
        let enable = !launchAtLoginEnabled

        Task { [weak self] in
            let result: Result<Void, any Error> = await Task.detached(priority: .userInitiated) {
                do {
                    if enable {
                        try startupController.enable()
                    } else {
                        try startupController.disable()
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }

            switch result {
            case .success:
                self.launchAtLoginEnabled = enable
                self.message = enable ? "Start at login enabled." : "Start at login disabled."
            case .failure(let error):
                self.message = error.localizedDescription
            }

            self.isBusy = false
        }
    }

    private func loadTasks(using startMode: TaskStartMode) {
        isBusy = true
        invalidateInFlightRefreshes()

        do {
            let discovery = try catalog.discoverTasks()
            var loadedTasks = discovery.tasks
            for index in loadedTasks.indices {
                let id = loadedTasks[index].id
                loadedTasks[index].isEnabled = enablementStore.isEnabled(id)
                loadedTasks[index].isRunning = runningTaskIDs.contains(id)
            }

            stopAllTaskScheduling()
            tasks = loadedTasks
            startEnabledTasks(using: startMode)
            if !discovery.skippedFolders.isEmpty {
                message = "Skipped invalid task folder(s): \(discovery.skippedFolders.joined(separator: ", "))"
            } else if startMode == .reload {
                message = "Tasks reloaded."
            }
        } catch {
            message = error.localizedDescription
        }

        isBusy = false
    }

    private func startEnabledTasks(using startMode: TaskStartMode) {
        for task in tasks where task.isEnabled {
            do {
                try startTask(task.id, using: startMode)
            } catch {
                if let index = indexOfTask(task.id) {
                    updateTask(at: index) { task in
                        task.isEnabled = false
                    }
                    enablementStore.setEnabled(false, taskID: task.id)
                }
                message = error.localizedDescription
            }
        }
    }

    private func startTask(_ taskID: String, using startMode: TaskStartMode) throws {
        guard let index = indexOfTask(taskID) else { return }

        let task = tasks[index]
        try runner.ensureAccess(for: task)
        stopTaskScheduling(taskID)

        switch task.configuration.triggerKind {
        case .directory:
            guard let directoryURL = task.configuration.resolvedDirectoryURL else {
                throw AutomationError.invalidConfiguration("\(task.configuration.name) needs a directoryPath in task.json.")
            }

            let monitor = DirectoryMonitor(url: directoryURL) { [weak self] in
                Task { @MainActor in
                    self?.scheduleTaskRun(taskID)
                }
            }

            try monitor.start()
            directoryMonitors[taskID] = monitor

            if startMode.shouldRunDirectoryTaskImmediately {
                requestTaskRun(taskID, source: .directory)
            }
        case .interval:
            let intervalSeconds = intervalSeconds(for: task.configuration)
            let launchPlan = intervalLaunchPlan(
                for: task,
                startMode: startMode,
                intervalSeconds: intervalSeconds,
                now: dateProvider()
            )

            if launchPlan.shouldRunWhenReady {
                requestTaskRun(taskID, source: .interval)
            }

            let firstDelay = launchPlan.shouldRunWhenReady ? intervalSeconds : launchPlan.initialDelaySeconds
            let eventHandler: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    self?.requestTaskRun(taskID, source: .interval)
                }
            }
            let timer = Self.makeIntervalTimer(
                firstDelay: firstDelay,
                repeatDelay: intervalSeconds,
                eventHandler: eventHandler
            )
            timer.resume()
            intervalTimers[taskID] = timer
        case .application:
            let monitor = ApplicationMonitor(configuration: task.configuration) { [weak self] event in
                Task { @MainActor in
                    self?.requestTaskRun(taskID, source: .application(event))
                }
            }

            try monitor.start()
            applicationMonitors[taskID] = monitor
        }
    }

    private func stopTaskScheduling(_ taskID: String) {
        pendingRunTasks[taskID]?.cancel()
        pendingRunTasks[taskID] = nil

        intervalTimers[taskID]?.cancel()
        intervalTimers[taskID] = nil

        quietHourDeferredRunTimers[taskID]?.cancel()
        quietHourDeferredRunTimers[taskID] = nil

        directoryMonitors[taskID]?.stop()
        directoryMonitors[taskID] = nil

        applicationMonitors[taskID]?.stop()
        applicationMonitors[taskID] = nil

        coalescedRunSources.removeValue(forKey: taskID)
    }

    private func stopAllTaskScheduling() {
        for taskID in tasks.map(\.id) {
            stopTaskScheduling(taskID)
        }
    }

    private func scheduleTaskRun(_ taskID: String) {
        pendingRunTasks[taskID]?.cancel()
        pendingRunTasks[taskID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.requestTaskRun(taskID, source: .directory)
            }
        }
    }

    private func startTaskRun(_ taskID: String, source: TaskRunRequestSource) {
        guard let index = indexOfTask(taskID) else { return }

        let task = tasks[index]
        runningTaskIDs.insert(taskID)
        updateTask(at: index) { task in
            task.isRunning = true
        }

        Task { [weak self, runner, task, taskID, source] in
            guard let self else { return }

            let outcome = await Task.detached(priority: .utility) { [runner, task, source] in
                let snapshotLoader = TaskSnapshotLoader()

                do {
                    try runner.run(task, event: source.applicationEvent)
                    return TaskRunOutcome.success(snapshotLoader.snapshot(for: task.paths))
                } catch {
                    return TaskRunOutcome.failure(
                        error.localizedDescription,
                        snapshotLoader.snapshot(for: task.paths)
                    )
                }
            }.value

            self.finishTaskRun(taskID, source: source, outcome: outcome)
        }
    }

    private func finishTaskRun(_ taskID: String, source: TaskRunRequestSource, outcome: TaskRunOutcome) {
        runningTaskIDs.remove(taskID)
        invalidateInFlightRefreshes()
        guard let refreshedIndex = indexOfTask(taskID) else {
            coalescedRunSources.removeValue(forKey: taskID)
            return
        }

        let updatedTask = updateTask(at: refreshedIndex) { task in
            task.isRunning = false

            switch outcome {
            case .success(let snapshot):
                task.snapshot = snapshot
            case .failure(_, let snapshot):
                task.snapshot = snapshot
            }
        }

        switch outcome {
        case .success:
            if source.isUserInitiated {
                message = "\(updatedTask.configuration.name) ran once."
            }
        case .failure(let message, _):
            self.message = message
        }

        if let nextSource = coalescedRunSources.removeValue(forKey: taskID), updatedTask.isEnabled {
            requestTaskRun(taskID, source: nextSource)
        }
    }

    private func shouldDeferForQuietHours(source: TaskRunRequestSource) -> Bool {
        source.defersForQuietHours && quietHours.contains(dateProvider())
    }

    private func deferTaskRunUntilQuietHoursEnd(_ taskID: String, source: TaskRunRequestSource) {
        guard quietHourDeferredRunTimers[taskID] == nil else { return }

        let now = dateProvider()
        let nextAllowedDate = quietHours.nextAllowedDate(after: now)
        let delay = max(nextAllowedDate.timeIntervalSince(now), 0)
        let eventHandler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.quietHourDeferredRunTimers[taskID] = nil
                guard self?.task(taskID)?.isEnabled == true else { return }
                self?.requestTaskRun(taskID, source: source)
            }
        }
        let timer = Self.makeOneShotTimer(delay: delay, eventHandler: eventHandler)
        timer.resume()
        quietHourDeferredRunTimers[taskID] = timer
    }

    private func intervalSeconds(for configuration: AutomationTaskConfiguration) -> Double {
        max(configuration.intervalSeconds ?? 0, 1)
    }

    private func intervalLaunchPlan(
        for task: AutomationTaskState,
        startMode: TaskStartMode,
        intervalSeconds: Double,
        now: Date
    ) -> IntervalLaunchPlan {
        guard startMode != .manualEnable else {
            return IntervalLaunchPlan(initialDelaySeconds: 0, shouldRunWhenReady: true)
        }

        guard let lastRunDate = Self.iso8601Formatter.date(from: task.snapshot.lastRunISO) else {
            return IntervalLaunchPlan(
                initialDelaySeconds: intervalSeconds,
                shouldRunWhenReady: false
            )
        }

        let elapsedSeconds = max(0, now.timeIntervalSince(lastRunDate))
        guard elapsedSeconds < intervalSeconds else {
            return IntervalLaunchPlan(initialDelaySeconds: 0, shouldRunWhenReady: true)
        }

        return IntervalLaunchPlan(
            initialDelaySeconds: intervalSeconds - elapsedSeconds,
            shouldRunWhenReady: false
        )
    }

    nonisolated private static func dispatchInterval(for seconds: Double) -> DispatchTimeInterval {
        .nanoseconds(Int(max(seconds, 0) * 1_000_000_000))
    }

    nonisolated private static func makeIntervalTimer(
        firstDelay: Double,
        repeatDelay: Double,
        eventHandler: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            wallDeadline: .now() + dispatchInterval(for: firstDelay),
            repeating: dispatchInterval(for: repeatDelay),
            leeway: timerLeeway(for: repeatDelay)
        )
        timer.setEventHandler(handler: eventHandler)
        return timer
    }

    nonisolated private static func makeOneShotTimer(
        delay: Double,
        eventHandler: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            wallDeadline: .now() + dispatchInterval(for: delay),
            leeway: timerLeeway(for: delay)
        )
        timer.setEventHandler(handler: eventHandler)
        return timer
    }

    nonisolated private static func timerLeeway(for seconds: Double) -> DispatchTimeInterval {
        seconds < 1 ? .milliseconds(10) : .seconds(5)
    }

    private func indexOfTask(_ taskID: String) -> Int? {
        tasks.firstIndex(where: { $0.id == taskID })
    }

    private func invalidateInFlightRefreshes() {
        refreshGeneration += 1
    }

    @discardableResult
    private func updateTask(at index: Int, _ update: (inout AutomationTaskState) -> Void) -> AutomationTaskState {
        update(&tasks[index])
        return tasks[index]
    }

    private func task(_ taskID: String) -> AutomationTaskState? {
        guard let index = indexOfTask(taskID) else { return nil }
        return tasks[index]
    }

    private func formattedQuietHour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = quietHours.calendar
        formatter.timeZone = quietHours.calendar.timeZone
        formatter.dateFormat = "h a"
        return formatter.string(from: date)
    }

    private enum TaskStartMode {
        case appLaunch
        case reload
        case manualEnable

        var shouldRunDirectoryTaskImmediately: Bool {
            switch self {
            case .appLaunch, .manualEnable:
                return true
            case .reload:
                return false
            }
        }
    }

    private enum TaskRunOutcome: Sendable {
        case success(AutomationTaskSnapshot)
        case failure(String, AutomationTaskSnapshot)
    }

    private struct IntervalLaunchPlan {
        let initialDelaySeconds: Double
        let shouldRunWhenReady: Bool
    }

    private static let iso8601Formatter = ISO8601DateFormatter()
}
