import Foundation

struct CodexUsageSnapshot: Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let label: String
        let allTime: String
        let monthToDate: String
        let yesterday: String
        let today: String
        let sparkline: String
    }

    let recordedPeriodText: String
    let estimateNoticeText: String
    let partialDataText: String?
    let modelSummaryText: String?
    let dataQualityText: String?
    let officialUsageText: String?
    let isEstimateAvailable: Bool
    let availabilityMessageText: String?
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

        guard summary.ledgerSchemaVersion == 2 else {
            return legacyPlaceholder(summary: summary)
        }

        let aggregation = loadLedgerAggregation(from: ledgerFile)
        guard ledgerIntegrityIsValid(summary: summary, aggregation: aggregation) else {
            return unavailablePlaceholder(
                recordedPeriodText: "Ledger update incomplete",
                estimateNoticeText: "Estimate unavailable until the ledger and summary match.",
                availabilityMessageText: "Codex ledger update incomplete; run the usage task again.",
                dataQualityText: "Ledger and summary generation mismatch"
            )
        }
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
            estimateNoticeText: estimateNotice(summary: summary),
            partialDataText: partialDataMessage(
                unavailableHosts: historicalUnavailableHosts.union(todayUnavailableHosts)
            ),
            modelSummaryText: modelSummary(summary: summary),
            dataQualityText: dataQualityMessage(summary: summary),
            officialUsageText: officialUsageMessage(summary: summary),
            isEstimateAvailable: true,
            availabilityMessageText: nil,
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

    private static func legacyPlaceholder(summary: SummaryDocument) -> CodexUsageSnapshot {
        unavailablePlaceholder(
            recordedPeriodText: "Legacy ledger through \(summary.latestRecordedDate)",
            estimateNoticeText: estimateNotice(summary: summary),
            availabilityMessageText: "Codex ledger rebuild required",
            dataQualityText: dataQualityMessage(summary: summary)
        )
    }

    private static func unavailablePlaceholder(
        recordedPeriodText: String,
        estimateNoticeText: String,
        availabilityMessageText: String,
        dataQualityText: String?
    ) -> CodexUsageSnapshot {
        let placeholderRow = Row(
            id: "total",
            label: "Total",
            allTime: "—",
            monthToDate: "—",
            yesterday: "—",
            today: "—",
            sparkline: ""
        )

        return CodexUsageSnapshot(
            recordedPeriodText: recordedPeriodText,
            estimateNoticeText: estimateNoticeText,
            partialDataText: nil,
            modelSummaryText: nil,
            dataQualityText: dataQualityText,
            officialUsageText: nil,
            isEstimateAvailable: false,
            availabilityMessageText: availabilityMessageText,
            totalRow: placeholderRow,
            hostRows: [],
            menuBarBadgeText: "TinkerBar",
            todayMenuBarBadgeText: "TinkerBar"
        )
    }

    private static func ledgerIntegrityIsValid(
        summary: SummaryDocument,
        aggregation: LedgerAggregation
    ) -> Bool {
        guard
            aggregation.wasLoaded,
            aggregation.invalidRowCount == 0,
            !aggregation.hasMissingGeneration,
            let generation = summary.ledgerGeneration,
            !generation.isEmpty,
            summary.rows == aggregation.rowCount
        else {
            return false
        }

        return aggregation.generations.isEmpty || aggregation.generations == [generation]
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

    private static func estimateNotice(summary: SummaryDocument) -> String {
        guard summary.ledgerSchemaVersion == 2 else {
            return "Legacy estimate; a unified ccusage v20 rebuild is required."
        }

        let version = summary.collector?.version.map { " \($0)" } ?? ""
        let tier = summary.collector?.speed?.capitalized ?? "Standard"
        return "Estimated \(tier)-tier API-equivalent cost via ccusage\(version); not billed spend."
    }

    private static func modelSummary(summary: SummaryDocument) -> String? {
        guard let models = summary.models?.observedRecent, !models.isEmpty else { return nil }
        return "Recent models: \(models.sorted().joined(separator: ", "))"
    }

    private static func dataQualityMessage(summary: SummaryDocument) -> String? {
        var messages: [String] = []

        if summary.ledgerSchemaVersion != 2 {
            messages.append("Ledger requires a v20 rebuild")
        }

        if summary.models?.catalogAvailable == false {
            messages.append("Current Codex model catalog unavailable")
        }

        if let models = summary.models?.notInCurrentCatalog, !models.isEmpty {
            messages.append("Local usage not in this Mac's current Codex catalog: \(models.sorted().joined(separator: ", "))")
        }

        if let models = summary.models?.fallbackAttributed, !models.isEmpty {
            messages.append("Fallback-attributed usage: \(models.sorted().joined(separator: ", "))")
        }

        if let rows = summary.models?.possiblyUnpricedRows, !rows.isEmpty {
            let label = rows.count == 1 ? "row" : "rows"
            messages.append("\(rows.count) usage \(label) may be unpriced")
        }

        if let warning = summary.official?.probeWarning, !warning.isEmpty {
            messages.append(warning)
        }

        return messages.isEmpty ? nil : messages.joined(separator: " • ")
    }

    private static func officialUsageMessage(summary: SummaryDocument) -> String? {
        guard
            summary.official?.accountUsage?.available == true,
            let bucket = summary.official?.accountUsage?.dailyUsageBuckets?
                .compactMap({ bucket -> (startDate: String, tokens: Int64)? in
                    guard let startDate = bucket.startDate, let tokens = bucket.tokens else {
                        return nil
                    }
                    return (startDate, tokens)
                })
                .max(by: { $0.startDate < $1.startDate })
        else {
            return nil
        }

        return "Official account activity: \(compactTokenCount(bucket.tokens)) tokens on \(bucket.startDate)"
    }

    private static func compactTokenCount(_ count: Int64) -> String {
        let value = Double(count)
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return "\(count)"
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
        aggregation.wasLoaded = true

        ledgerText.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            guard let row = try? decoder.decode(LedgerRow.self, from: Data(line.utf8)) else {
                aggregation.invalidRowCount += 1
                return
            }

            aggregation.rowCount += 1
            if let generation = row.ledgerGeneration, !generation.isEmpty {
                aggregation.generations.insert(generation)
            } else {
                aggregation.hasMissingGeneration = true
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
    var wasLoaded = false
    var rowCount = 0
    var invalidRowCount = 0
    var generations: Set<String> = []
    var hasMissingGeneration = false
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
    struct Collector: Decodable {
        let version: String?
        let speed: String?
    }

    struct ModelDiagnostics: Decodable {
        struct PossiblyUnpricedRow: Decodable {}

        let observedRecent: [String]?
        let catalogAvailable: Bool?
        let notInCurrentCatalog: [String]?
        let fallbackAttributed: [String]?
        let possiblyUnpricedRows: [PossiblyUnpricedRow]?
    }

    struct OfficialSnapshot: Decodable {
        struct AccountUsage: Decodable {
            struct DailyUsageBucket: Decodable {
                let startDate: String?
                let tokens: Int64?

                private enum CodingKeys: String, CodingKey {
                    case startDate
                    case tokens
                }

                init(from decoder: Decoder) throws {
                    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                        startDate = nil
                        tokens = nil
                        return
                    }
                    startDate = try? container.decode(String.self, forKey: .startDate)
                    tokens = try? container.decode(Int64.self, forKey: .tokens)
                }
            }

            let available: Bool
            let dailyUsageBuckets: [DailyUsageBucket]?

            private enum CodingKeys: String, CodingKey {
                case available
                case dailyUsageBuckets
            }

            init(from decoder: Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    available = false
                    dailyUsageBuckets = nil
                    return
                }
                available = (try? container.decode(Bool.self, forKey: .available)) ?? false
                dailyUsageBuckets = try? container.decode(
                    [DailyUsageBucket].self,
                    forKey: .dailyUsageBuckets
                )
            }
        }

        let probeWarning: String?
        let accountUsage: AccountUsage?

        private enum CodingKeys: String, CodingKey {
            case probeWarning
            case accountUsage
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                probeWarning = nil
                accountUsage = nil
                return
            }
            probeWarning = try? container.decode(String.self, forKey: .probeWarning)
            accountUsage = try? container.decode(AccountUsage.self, forKey: .accountUsage)
        }
    }

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
    let ledgerSchemaVersion: Int?
    let ledgerGeneration: String?
    let rows: Int?
    let collector: Collector?
    let models: ModelDiagnostics?
    let official: OfficialSnapshot?
    let latestRecordedDate: String
    let collection: Collection?
    let monthToDate: MonthToDate
    let yesterday: DaySummary?
    let today: DaySummary?
    let latestByHost: [LatestHostEntry]
}

private struct LedgerRow: Decodable {
    let ledgerGeneration: String?
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
