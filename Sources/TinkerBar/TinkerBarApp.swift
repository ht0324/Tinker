import SwiftUI

@main
struct TinkerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtime = AutomationRuntime()
    @AppStorage("showsTodaySpendingInMenuBar") private var showsTodayEstimateInMenuBar = true

    var body: some Scene {
        MenuBarExtra {
            ContentView(runtime: runtime, showsTodayEstimateInMenuBar: $showsTodayEstimateInMenuBar)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarTitle: String {
        runtime.menuBarTitle(showingTodayEstimate: showsTodayEstimateInMenuBar)
    }

    private var menuBarSystemImage: String {
        runtime.hasEnabledTasks ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver"
    }

    private var showsAvailableEstimate: Bool {
        showsTodayEstimateInMenuBar && runtime.codexUsageSnapshot?.isEstimateAvailable == true
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if showsAvailableEstimate {
            Text(menuBarTitle)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .accessibilityLabel("Estimated today \(menuBarTitle)")
        } else {
            Image(systemName: menuBarSystemImage)
                .accessibilityLabel(menuBarTitle)
        }
    }
}
