import SwiftUI

@main
struct TinkerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtime = AutomationRuntime()
    @AppStorage("showsTodaySpendingInMenuBar") private var showsTodaySpendingInMenuBar = true

    var body: some Scene {
        MenuBarExtra {
            ContentView(runtime: runtime, showsTodaySpendingInMenuBar: $showsTodaySpendingInMenuBar)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarTitle: String {
        runtime.menuBarTitle(showingTodaySpending: showsTodaySpendingInMenuBar)
    }

    private var menuBarSystemImage: String {
        runtime.hasEnabledTasks ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver"
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if showsTodaySpendingInMenuBar {
            Text(menuBarTitle)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
            .accessibilityLabel("Today \(menuBarTitle)")
        } else {
            Image(systemName: menuBarSystemImage)
                .accessibilityLabel(menuBarTitle)
        }
    }
}
