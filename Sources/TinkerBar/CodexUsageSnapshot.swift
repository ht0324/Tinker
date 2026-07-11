import Foundation

struct CodexUsageSnapshot: Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let allTime: String
        let monthToDate: String
        let yesterday: String
        let today: String
        let sparkline: String
    }

    let recordedPeriodText: String
    let partialDataText: String?
    let totalRow: Row
    let hostRows: [Row]
    let menuBarBadgeText: String
    let todayMenuBarBadgeText: String

    static func load(summaryFile: URL, ledgerFile: URL) -> CodexUsageSnapshot? {
        CodexUsageSnapshotCache.shared.load(summaryFile: summaryFile, ledgerFile: ledgerFile) {
            loadUncached(summaryFile: summaryFile, ledgerFile: ledgerFile)
        }
    }

    private static func loadUncached(summaryFile: URL, ledgerFile: URL) -> CodexUsageSnapshot? {
        guard
            let summaryData = try? Data(contentsOf: summaryFile),
            let summary = try? JSONDecoder().decode(SummaryDocument.self, from: summaryData)
        else {
            return nil
        }

        let aggregation = loadLedgerAggregation(from: ledgerFile)
        let sortedDates = Array(aggregation.dates).sorted()
        let recentDates = Array(sortedDates.suffix(7))
        let hosts = orderedHosts(summary: summary, ledgerHosts: aggregation.hosts)
        let historicalUnavailableHosts = Set(summary.collection?.historicalFailedHosts ?? [])
        let todayUnavailableHosts = Set(summary.today?.unavailableHosts ?? [])

        let recentDailyTotals = recentDates.map { aggregation.dailyTotals[$0, default: 0] }

        var recentDailyByHost: [String: [Double]] = [:]
        for host in hosts {
            let dateTotals = aggregation.dailyTotalsByHost[host, default: [:]]
            recentDailyByHost[host] = recentDates.map { dateTotals[$0, default: 0] }
        }

        let allTimeByHost = hosts.map { host in
            let totals = aggregation.hostTotals[host] ?? HostTotals()
            return HostCost(host: host, costUSD: totals.totalCostUSD)
        }
        let monthToDateByHost = summary.monthToDate.byHost.map {
            HostCost(host: $0.host, costUSD: $0.totalCostUSD)
        }
        let yesterday = resolvedYesterday(summary: summary, aggregation: aggregation, hosts: hosts)
        let todayByHost = summary.today?.byHost.map {
            HostCost(host: $0.host, costUSD: $0.costUSD)
        } ?? []
        let earliestRecordedDate = aggregation.earliestRecordedDate ?? summary.latestRecordedDate
        let todayTotalUSD = summary.today?.totalCostUSD ?? 0
        let hasHistoricalGaps = !historicalUnavailableHosts.isEmpty
        let hasTodayGaps = !todayUnavailableHosts.isEmpty

        return CodexUsageSnapshot(
            recordedPeriodText: "Recorded \(earliestRecordedDate) to \(summary.latestRecordedDate)",
            partialDataText: partialDataMessage(
                unavailableHosts: historicalUnavailableHosts.union(todayUnavailableHosts)
            ),
            totalRow: Row(
                id: "total",
                label: "Total",
                allTime: lowerBoundCurrency(aggregation.allTimeTotalUSD, hasGap: hasHistoricalGaps),
                monthToDate: lowerBoundCurrency(summary.monthToDate.totalCostUSD, hasGap: hasHistoricalGaps),
                yesterday: lowerBoundCurrency(yesterday.totalUSD, hasGap: hasHistoricalGaps),
                today: lowerBoundCurrency(todayTotalUSD, hasGap: hasTodayGaps),
                sparkline: sparkline(for: recentDailyTotals)
            ),
            hostRows: makeHostRows(
                allTime: allTimeByHost,
                monthToDate: monthToDateByHost,
                yesterday: yesterday.byHost,
                today: todayByHost,
                recentDailyByHost: recentDailyByHost,
                historicalUnavailableHosts: historicalUnavailableHosts,
                todayUnavailableHosts: todayUnavailableHosts
            ),
            menuBarBadgeText: partialPrefix(hasGaps: hasHistoricalGaps)
                + compactCurrency(summary.monthToDate.totalCostUSD),
            todayMenuBarBadgeText: partialPrefix(hasGaps: hasTodayGaps)
                + trailingDollarCompactCurrency(todayTotalUSD)
        )
    }

    private static func resolvedYesterday(
        summary: SummaryDocument,
        aggregation: LedgerAggregation,
        hosts: [String]
    ) -> (totalUSD: Double, byHost: [HostCost]) {
        if let yesterday = summary.yesterday {
            let byHost = yesterday.byHost.map {
                HostCost(host: $0.host, costUSD: $0.costUSD)
            }
            return (yesterday.totalCostUSD, byHost)
        }

        guard summary.latestRecordedDate == yesterdayDateString(inTimezone: summary.timezone) else {
            return (0, [])
        }

        let byHost = hosts.compactMap { host -> HostCost? in
            let costUSD = aggregation.dailyTotalsByHost[host]?[summary.latestRecordedDate] ?? 0
            guard costUSD > 0 else { return nil }
            return HostCost(host: host, costUSD: costUSD)
        }

        return (
            aggregation.dailyTotals[summary.latestRecordedDate, default: 0],
            byHost
        )
    }

    private static func yesterdayDateString(inTimezone identifier: String, now: Date = Date()) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .current

        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: yesterday)
    }

    private static func makeHostRows(
        allTime: [HostCost],
        monthToDate: [HostCost],
        yesterday: [HostCost],
        today: [HostCost],
        recentDailyByHost: [String: [Double]],
        historicalUnavailableHosts: Set<String>,
        todayUnavailableHosts: Set<String>
    ) -> [Row] {
        let monthToDateCosts = costsByHost(monthToDate)
        let yesterdayCosts = costsByHost(yesterday)
        let todayCosts = costsByHost(today)

        return allTime
            .sorted { hostSortKey($0.host) < hostSortKey($1.host) }
            .map { host in
                let hasHistoricalGap = historicalUnavailableHosts.contains(host.host)
                return Row(
                    id: host.host,
                    label: hostDisplayName(host.host),
                    allTime: lowerBoundCurrency(host.costUSD, hasGap: hasHistoricalGap),
                    monthToDate: lowerBoundCurrency(
                        monthToDateCosts[host.host, default: 0],
                        hasGap: hasHistoricalGap
                    ),
                    yesterday: hasHistoricalGap
                        ? "—"
                        : wholeCurrency(yesterdayCosts[host.host, default: 0]),
                    today: todayUnavailableHosts.contains(host.host)
                        ? "—"
                        : wholeCurrency(todayCosts[host.host, default: 0]),
                    sparkline: sparkline(for: recentDailyByHost[host.host, default: []])
                )
            }
    }

    private static func costsByHost(_ costs: [HostCost]) -> [String: Double] {
        Dictionary(costs.map { ($0.host, $0.costUSD) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func partialDataMessage(unavailableHosts: Set<String>) -> String? {
        guard !unavailableHosts.isEmpty else { return nil }

        let description = unavailableHosts
            .map(hostDisplayName)
            .sorted()
            .joined(separator: ", ")
        return "Partial data; unavailable: \(description)"
    }

    private static func hostDisplayName(_ host: String) -> String {
        host == "local" ? "MacBook" : host.capitalized
    }

    private static func lowerBoundCurrency(_ amount: Double, hasGap: Bool) -> String {
        partialPrefix(hasGaps: hasGap) + wholeCurrency(amount)
    }

    private static func wholeCurrency(_ amount: Double) -> String {
        wholeCurrencyFormatter.string(from: NSNumber(value: amount)) ?? "$\(Int(amount.rounded()))"
    }

    private static func compactCurrency(_ amount: Double) -> String {
        let absoluteAmount = abs(amount)

        if absoluteAmount >= 1_000 {
            return "$" + compactThousands(amount)
        }

        if absoluteAmount >= 100 {
            return "$\(Int(amount.rounded()))"
        }

        if absoluteAmount >= 10 {
            return String(format: "$%.1f", amount)
        }

        return String(format: "$%.2f", amount)
    }

    private static func trailingDollarCompactCurrency(_ amount: Double) -> String {
        abs(amount) >= 1_000 ? compactThousands(amount) + "$" : "\(Int(amount.rounded()))$"
    }

    private static func compactThousands(_ amount: Double) -> String {
        String(format: "%.1fk", amount / 1_000).replacingOccurrences(of: ".0k", with: "k")
    }

    private static func partialPrefix(hasGaps: Bool) -> String {
        hasGaps ? "≥" : ""
    }

    private static func orderedHosts(summary: SummaryDocument, ledgerHosts: Set<String>) -> [String] {
        var orderedHosts = summary.collection?.expectedHosts ?? []

        for host in summary.monthToDate.byHost.map(\.host) where !orderedHosts.contains(host) {
            orderedHosts.append(host)
        }

        for host in summary.latestByHost.map(\.host) where !orderedHosts.contains(host) {
            orderedHosts.append(host)
        }

        for host in ledgerHosts where !orderedHosts.contains(host) {
            orderedHosts.append(host)
        }

        return orderedHosts.sorted { hostSortKey($0) < hostSortKey($1) }
    }

    private static func loadLedgerAggregation(from ledgerFile: URL) -> LedgerAggregation {
        guard let ledgerText = try? String(contentsOf: ledgerFile, encoding: .utf8) else {
            return LedgerAggregation()
        }

        let decoder = JSONDecoder()
        var aggregation = LedgerAggregation()

        ledgerText.enumerateLines { line, _ in
            guard let row = try? decoder.decode(LedgerRow.self, from: Data(line.utf8)) else {
                return
            }

            aggregation.allTimeTotalUSD += row.costUSD
            aggregation.dates.insert(row.date)
            aggregation.hosts.insert(row.host)
            aggregation.dailyTotals[row.date, default: 0] += row.costUSD
            aggregation.dailyTotalsByHost[row.host, default: [:]][row.date, default: 0] += row.costUSD

            if let earliestRecordedDate = aggregation.earliestRecordedDate {
                aggregation.earliestRecordedDate = min(earliestRecordedDate, row.date)
            } else {
                aggregation.earliestRecordedDate = row.date
            }

            var hostTotals = aggregation.hostTotals[row.host] ?? HostTotals()
            hostTotals.totalCostUSD += row.costUSD
            aggregation.hostTotals[row.host] = hostTotals
        }

        return aggregation
    }

    private static func sparkline(for values: [Double]) -> String {
        guard !values.isEmpty else { return "" }

        let blocks = Array("▁▂▃▄▅▆▇█")
        let maximumValue = values.max() ?? 0
        guard maximumValue > 0 else {
            return String(repeating: String(blocks[0]), count: values.count)
        }

        return values.map { value in
            let normalized = max(0, min(1, value / maximumValue))
            let index = Int((normalized * Double(blocks.count - 1)).rounded())
            return String(blocks[index])
        }.joined()
    }

    private static func hostSortKey(_ host: String) -> String {
        host == "local" ? "0-local" : "1-\(host)"
    }

    private static let wholeCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

private struct LedgerAggregation {
    var earliestRecordedDate: String?
    var allTimeTotalUSD = 0.0
    var dates: Set<String> = []
    var hosts: Set<String> = []
    var dailyTotals: [String: Double] = [:]
    var dailyTotalsByHost: [String: [String: Double]] = [:]
    var hostTotals: [String: HostTotals] = [:]
}

private struct HostTotals {
    var totalCostUSD = 0.0
}

private struct HostCost {
    let host: String
    let costUSD: Double
}

private struct SummaryDocument: Decodable {
    struct Collection: Decodable {
        let expectedHosts: [String]
        let historicalFailedHosts: [String]
    }

    struct MonthToDate: Decodable {
        struct HostEntry: Decodable {
            let host: String
            let totalCostUSD: Double
        }

        let totalCostUSD: Double
        let byHost: [HostEntry]
    }

    struct LatestHostEntry: Decodable {
        let host: String
        let costUSD: Double
    }

    struct DaySummary: Decodable {
        let totalCostUSD: Double
        let byHost: [LatestHostEntry]
        let unavailableHosts: [String]?
    }

    let timezone: String
    let latestRecordedDate: String
    let collection: Collection?
    let monthToDate: MonthToDate
    let yesterday: DaySummary?
    let today: DaySummary?
    let latestByHost: [LatestHostEntry]
}

private struct LedgerRow: Decodable {
    let date: String
    let host: String
    let costUSD: Double
}

private final class CodexUsageSnapshotCache: @unchecked Sendable {
    static let shared = CodexUsageSnapshotCache()

    private struct CacheKey: Hashable {
        let summaryPath: String
        let ledgerPath: String
    }

    private struct CacheEntry {
        let summaryModificationDate: Date?
        let ledgerModificationDate: Date?
        let snapshot: CodexUsageSnapshot?
    }

    private let lock = NSLock()
    private var entries: [CacheKey: CacheEntry] = [:]
    private let fileManager = FileManager.default

    func load(summaryFile: URL, ledgerFile: URL, builder: () -> CodexUsageSnapshot?) -> CodexUsageSnapshot? {
        let key = CacheKey(summaryPath: summaryFile.path, ledgerPath: ledgerFile.path)
        let summaryModificationDate = modificationDate(for: summaryFile)
        let ledgerModificationDate = modificationDate(for: ledgerFile)

        lock.lock()
        if let cached = entries[key],
           cached.summaryModificationDate == summaryModificationDate,
           cached.ledgerModificationDate == ledgerModificationDate {
            let snapshot = cached.snapshot
            lock.unlock()
            return snapshot
        }
        lock.unlock()

        let snapshot = builder()

        lock.lock()
        entries[key] = CacheEntry(
            summaryModificationDate: summaryModificationDate,
            ledgerModificationDate: ledgerModificationDate,
            snapshot: snapshot
        )
        lock.unlock()

        return snapshot
    }

    private func modificationDate(for url: URL) -> Date? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return resourceValues?.contentModificationDate
    }
}
