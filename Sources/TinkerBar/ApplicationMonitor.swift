import AppKit
import Foundation

enum ApplicationMonitorError: LocalizedError {
    case missingTarget(String)

    var errorDescription: String? {
        switch self {
        case .missingTarget(let taskName):
            return "\(taskName) needs an applicationName or bundleIdentifier in task.json."
        }
    }
}

final class ApplicationMonitor: @unchecked Sendable {
    typealias EventHandler = @Sendable (ApplicationTriggerEvent) -> Void

    private let configuration: AutomationTaskConfiguration
    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let eventHandler: EventHandler
    private var observerTokens: [NSObjectProtocol] = []
    private var isMatchedApplicationRunning = false

    init(
        configuration: AutomationTaskConfiguration,
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        eventHandler: @escaping EventHandler
    ) {
        self.configuration = configuration
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.eventHandler = eventHandler
    }

    func start() throws {
        guard configuration.hasApplicationTarget else {
            throw ApplicationMonitorError.missingTarget(configuration.name)
        }

        stop()

        observerTokens = [
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handlePotentialOpen(notification)
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handlePotentialOpen(notification)
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleClose(notification)
            },
        ]

        isMatchedApplicationRunning = workspace.runningApplications.contains(where: matches(_:))
        if isMatchedApplicationRunning {
            eventHandler(.opened)
        }
    }

    func stop() {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func handlePotentialOpen(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard matches(application) else { return }
        guard !isMatchedApplicationRunning else { return }

        isMatchedApplicationRunning = true
        eventHandler(.opened)
    }

    private func handleClose(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard matches(application) else { return }

        isMatchedApplicationRunning = false
        eventHandler(.closed)
    }

    private func matches(_ application: NSRunningApplication) -> Bool {
        let configuredBundleID = normalized(configuration.bundleIdentifier)
        let configuredName = normalized(configuration.applicationName)

        if let configuredBundleID,
           let bundleIdentifier = normalized(application.bundleIdentifier),
           bundleIdentifier == configuredBundleID {
            return true
        }

        guard let configuredName else { return false }

        if normalized(application.localizedName) == configuredName {
            return true
        }

        let bundleName = application.bundleURL?.deletingPathExtension().lastPathComponent
        return normalized(bundleName) == configuredName
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
