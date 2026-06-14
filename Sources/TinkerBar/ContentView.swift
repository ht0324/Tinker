import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var runtime: AutomationRuntime
    @Binding var showsTodaySpendingInMenuBar: Bool

    var body: some View {
        Group {
            Text(runtime.summaryText)

            if let usage = runtime.codexUsageSnapshot {
                Text("Codex \(usage.formattedTodayTotal) today")

                Text("All time \(usage.formattedAllTimeTotal)")
            }

            Text(runtime.quietModeStatusText)

            Toggle("Show Today in Menu Bar", isOn: $showsTodaySpendingInMenuBar)
                .disabled(runtime.codexUsageSnapshot == nil)

            ForEach(runtime.tasks) { task in
                Menu(task.configuration.name) {
                    if let usage = task.snapshot.codexUsage {
                        Text("Recorded \(usage.earliestRecordedDate) to \(usage.latestRecordedDate)")
                        usageTableLine(usageTableHeader())
                        usageTableLine(usageTableRow(
                            label: "Total",
                            allTime: usage.formattedAllTimeTotal,
                            monthToDate: usage.formattedMonthToDateTotal,
                            yesterday: usage.formattedYesterdayTotal,
                            today: usage.formattedTodayTotal,
                            sparkline: usage.totalSparkline
                        ))

                        ForEach(usage.orderedAllTimeHostSummaries) { host in
                            usageTableLine(usageHostTableRow(for: host, usage: usage))
                        }

                        Divider()
                    }

                    Text(task.configuration.detail)
                    Text("\(task.configuration.triggerDescription): \(task.configuration.triggerDetail)")
                    Text("Task folder: \(task.paths.taskDirectory.lastPathComponent)")
                    Text("Task ready: \(task.snapshot.filesInstalled ? "Yes" : "No")")
                    Text("Last run: \(formattedTimestamp(task.snapshot.lastRunISO))")
                    Text("Last success: \(formattedTimestamp(task.snapshot.lastSuccessISO))")

                    if !task.snapshot.lastOutput.isEmpty {
                        Text("Last output: \(displayLastOutput(task.snapshot.lastOutput))")
                    }

                    if !task.snapshot.lastError.isEmpty {
                        Text("Last error: \(task.snapshot.lastError)")
                    }

                    Divider()

                    Button(task.isEnabled ? "Turn Off" : "Turn On") {
                        runtime.toggleTask(task.id)
                    }
                    .disabled(runtime.isBusy || task.isRunning)

                    Button("Run Now") {
                        runtime.runTaskNow(task.id)
                    }
                    .disabled(runtime.isBusy || task.isRunning)

                    Divider()

                    Button("Open Task Folder") {
                        runtime.openTaskFolder(task.id)
                    }

                    Button("Open Target") {
                        runtime.openTaskTarget(task.id)
                    }

                    Button("Open Log") {
                        runtime.openTaskLog(task.id)
                    }
                }
            }

            Button("Reload Tasks") {
                runtime.reloadTasks()
            }
            .disabled(runtime.isBusy)

            Button("Open Tasks Folder") {
                runtime.openTasksFolder()
            }

            Button(runtime.launchAtLoginEnabled ? "Disable Start at Login" : "Start at Login") {
                runtime.toggleLaunchAtLogin()
            }
            .disabled(runtime.isBusy)

            if !runtime.message.isEmpty {
                Text(runtime.message)
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            runtime.menuDidAppear()
        }
    }

    private func usageTableLine(_ value: String) -> some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
    }

    private func usageTableHeader() -> String {
        usageTableRow(label: "Host", allTime: "All time", monthToDate: "MTD", yesterday: "Yday", today: "Today", sparkline: "7d")
    }

    private func usageHostTableRow(for host: CodexUsageSnapshot.HostSummary, usage: CodexUsageSnapshot) -> String {
        let monthToDate = usage.monthToDateByHost.first { $0.host == host.host }?.totalCostUSD ?? 0
        let yesterday = usage.yesterdayByHost.first { $0.host == host.host }?.costUSD ?? 0
        let today = usage.todayByHost.first { $0.host == host.host }?.costUSD ?? 0

        return usageTableRow(
            label: CodexUsageSnapshot.hostDisplayName(host.host),
            allTime: CodexUsageSnapshot.wholeCurrency(host.totalCostUSD),
            monthToDate: CodexUsageSnapshot.wholeCurrency(monthToDate),
            yesterday: CodexUsageSnapshot.wholeCurrency(yesterday),
            today: CodexUsageSnapshot.wholeCurrency(today),
            sparkline: usage.sparkline(for: host.host)
        )
    }

    private func usageTableRow(label: String, allTime: String, monthToDate: String, yesterday: String, today: String, sparkline: String) -> String {
        "\(padded(label, to: 8))  \(leftPadded(allTime, to: 10))  \(leftPadded(monthToDate, to: 10))  \(leftPadded(yesterday, to: 8))  \(leftPadded(today, to: 8))  \(leftPadded(sparkline, to: 7))"
    }

    private func padded(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private func leftPadded(_ value: String, to width: Int) -> String {
        guard value.count < width else { return value }
        return String(repeating: " ", count: width - value.count) + value
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private func formattedTimestamp(_ value: String) -> String {
        guard !value.isEmpty else { return "Never" }

        guard let date = Self.iso8601Formatter.date(from: value) else { return value }

        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func displayLastOutput(_ value: String) -> String {
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).lastPathComponent
        }

        return truncated(value, maxLength: 56)
    }

    private func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return "\(value.prefix(maxLength - 3))..."
    }
}
