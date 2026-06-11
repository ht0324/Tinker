import Foundation

enum StartupControllerError: LocalizedError {
    case notRunningFromAppBundle
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            return "Start at login only works when TinkerBar is launched from its .app bundle."
        case .commandFailed(let message):
            return message
        }
    }
}

struct StartupController: @unchecked Sendable {
    static let agentLabel = "com.huntae.tinkerbar.startup"

    private let fileManager = FileManager.default
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    var launchAgentsDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    var launchAgentPlist: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.agentLabel).plist")
    }

    var bundleURL: URL {
        Bundle.main.bundleURL
    }

    func isEnabled() -> Bool {
        fileManager.fileExists(atPath: launchAgentPlist.path)
    }

    func enable() throws {
        guard bundleURL.pathExtension == "app" else {
            throw StartupControllerError.notRunningFromAppBundle
        }

        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try launchAgentPlistContents().write(to: launchAgentPlist, atomically: true, encoding: .utf8)

        _ = CommandRunner.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", launchAgentPlist.path])
        let result = CommandRunner.run("/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", launchAgentPlist.path])

        guard result.exitCode == 0 else {
            throw StartupControllerError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func disable() throws {
        _ = CommandRunner.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", launchAgentPlist.path])
        try? fileManager.removeItem(at: launchAgentPlist)
    }

    private func launchAgentPlistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-gj</string>
                <string>\(xmlEscaped(bundleURL.path))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
