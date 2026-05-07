import Foundation

struct CodexUsageSnapshot: Sendable {
    struct HostSummary: Identifiable, Hashable, Sendable {
        let host: String
        let rows: Int
        let totalCostUSD: Double
        let latestDate: String

        var id: String { host }
    }

    struct HostLatest: Identifiable, Hashable, Sendable {
        let host: String
        let date: String
        let costUSD: Double
        let totalTokens: Int

        var id: String { host }
    }

    struct DailyCost: Identifiable, Hashable, Sendable {
        let date: String
        let costUSD: Double

        var id: String { date }
    }

    let generatedAt: String
    let timezone: String
    let earliestRecordedDate: String
    let latestRecordedDate: String
    let allTimeTotalUSD: Double
    let allTimeByHost: [HostSummary]
    let monthToDateTotalUSD: Double
    let monthToDateByHost: [HostSummary]
    let yesterdayDate: String
    let yesterdayTotalUSD: Double
    let yesterdayByHost: [HostLatest]
    let todayDate: String
    let todayTotalUSD: Double
    let todayByHost: [HostLatest]
    let latestByHost: [HostLatest]
    let recentDailyTotals: [DailyCost]
    let recentDailyByHost: [String: [DailyCost]]

    var menuBarBadgeText: String {
        Self.compactCurrency(monthToDateTotalUSD)
    }

    var todayMenuBarBadgeText: String {
        Self.trailingDollarCompactCurrency(todayTotalUSD)
    }

    var formattedMonthToDateTotal: String {
        Self.wholeCurrency(monthToDateTotalUSD)
    }

    var formattedAllTimeTotal: String {
        Self.wholeCurrency(allTimeTotalUSD)
    }

    var formattedYesterdayTotal: String {
        Self.wholeCurrency(yesterdayTotalUSD)
    }

    var formattedTodayTotal: String {
        Self.wholeCurrency(todayTotalUSD)
    }

    var totalSparkline: String {
        Self.sparkline(for: recentDailyTotals.map(\.costUSD))
    }

    var orderedAllTimeHostSummaries: [HostSummary] {
        allTimeByHost.sorted { Self.hostSortKey($0.host) < Self.hostSortKey($1.host) }
    }

    func sparkline(for host: String) -> String {
        Self.sparkline(for: recentDailyByHost[host, default: []].map(\.costUSD))
    }

    static func hostDisplayName(_ host: String) -> String {
        switch host {
        case "local":
            return "MacBook"
        default:
            return host.capitalized
        }
    }

    static func wholeCurrency(_ amount: Double) -> String {
        wholeCurrencyFormatter.string(from: NSNumber(value: amount)) ?? "$\(Int(amount.rounded()))"
    }

    static func compactCurrency(_ amount: Double) -> String {
        let absoluteAmount = abs(amount)

        if absoluteAmount >= 1_000 {
            let compact = String(format: "$%.1fk", amount / 1_000)
            return compact.replacingOccurrences(of: ".0k", with: "k")
        }

        if absoluteAmount >= 100 {
            return "$\(Int(amount.rounded()))"
        }

        if absoluteAmount >= 10 {
            return String(format: "$%.1f", amount)
        }

        return String(format: "$%.2f", amount)
    }

    static func trailingDollarCompactCurrency(_ amount: Double) -> String {
        let absoluteAmount = abs(amount)

        if absoluteAmount >= 1_000 {
            let compact = String(format: "%.1fk", amount / 1_000)
            return "\(compact.replacingOccurrences(of: ".0k", with: "k"))$"
        }

        return "\(Int(amount.rounded()))$"
    }

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

        let recentDailyTotals = recentDates.map { date in
            DailyCost(date: date, costUSD: aggregation.dailyTotals[date, default: 0])
        }

        var recentDailyByHost: [String: [DailyCost]] = [:]
        for host in hosts {
            let dateTotals = aggregation.dailyTotalsByHost[host, default: [:]]
            recentDailyByHost[host] = recentDates.map { date in
                DailyCost(date: date, costUSD: dateTotals[date, default: 0])
            }
        }

        let allTimeByHost = hosts.map { host in
            let totals = aggregation.hostTotals[host] ?? HostTotals()
            return HostSummary(
                host: host,
                rows: totals.rows,
                totalCostUSD: totals.totalCostUSD,
                latestDate: totals.latestDate
            )
        }
        let yesterdayByHost = summary.yesterday?.byHost.map {
            HostLatest(host: $0.host, date: $0.date, costUSD: $0.costUSD, totalTokens: $0.totalTokens)
        } ?? hosts.compactMap { host in
            let costUSD = aggregation.dailyTotalsByHost[host]?[summary.latestRecordedDate] ?? 0
            guard costUSD > 0 else { return nil }
            return HostLatest(host: host, date: summary.latestRecordedDate, costUSD: costUSD, totalTokens: 0)
        }

        return CodexUsageSnapshot(
            generatedAt: summary.generatedAt,
            timezone: summary.timezone,
            earliestRecordedDate: aggregation.earliestRecordedDate ?? summary.latestRecordedDate,
            latestRecordedDate: summary.latestRecordedDate,
            allTimeTotalUSD: aggregation.allTimeTotalUSD,
            allTimeByHost: allTimeByHost,
            monthToDateTotalUSD: summary.monthToDate.totalCostUSD,
            monthToDateByHost: summary.monthToDate.byHost.map {
                HostSummary(host: $0.host, rows: $0.rows, totalCostUSD: $0.totalCostUSD, latestDate: $0.latestDate)
            },
            yesterdayDate: summary.yesterday?.date ?? summary.latestRecordedDate,
            yesterdayTotalUSD: summary.yesterday?.totalCostUSD ?? aggregation.dailyTotals[summary.latestRecordedDate, default: 0],
            yesterdayByHost: yesterdayByHost,
            todayDate: summary.today?.date ?? "",
            todayTotalUSD: summary.today?.totalCostUSD ?? 0,
            todayByHost: summary.today?.byHost.map {
                HostLatest(host: $0.host, date: $0.date, costUSD: $0.costUSD, totalTokens: $0.totalTokens)
            } ?? [],
            latestByHost: summary.latestByHost.map {
                HostLatest(host: $0.host, date: $0.date, costUSD: $0.costUSD, totalTokens: $0.totalTokens)
            },
            recentDailyTotals: recentDailyTotals,
            recentDailyByHost: recentDailyByHost
        )
    }

    private static func orderedHosts(summary: SummaryDocument, ledgerHosts: Set<String>) -> [String] {
        var orderedHosts = summary.monthToDate.byHost.map(\.host)

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
            hostTotals.rows += 1
            hostTotals.totalCostUSD += row.costUSD
            hostTotals.latestDate = max(hostTotals.latestDate, row.date)
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
    var rows = 0
    var totalCostUSD = 0.0
    var latestDate = ""
}

private struct SummaryDocument: Decodable {
    struct MonthToDate: Decodable {
        struct HostEntry: Decodable {
            let host: String
            let rows: Int
            let totalCostUSD: Double
            let latestDate: String
        }

        let totalCostUSD: Double
        let byHost: [HostEntry]
    }

    struct LatestHostEntry: Decodable {
        let host: String
        let date: String
        let costUSD: Double
        let totalTokens: Int
    }

    struct DaySummary: Decodable {
        let date: String
        let totalCostUSD: Double
        let byHost: [LatestHostEntry]
    }

    let generatedAt: String
    let timezone: String
    let latestRecordedDate: String
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
