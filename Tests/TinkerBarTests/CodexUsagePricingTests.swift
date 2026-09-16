import Foundation
import XCTest
@testable import TinkerBar

final class CodexUsagePricingTests: XCTestCase {
    func testUnpricedTodayIsNotDisplayedAsZeroAndDoesNotHidePricedHistory() throws {
        let snapshot = try loadSnapshot(
            history: [row(date: "2026-09-14", cost: 25, tokens: 1_000)],
            today: [row(date: "2026-09-15", cost: 0, tokens: 52_352_207)]
        )

        XCTAssertEqual(snapshot.totalRow.today, "Unpriced")
        XCTAssertEqual(snapshot.todayMenuBarBadgeText, "Unpriced")
        XCTAssertEqual(snapshot.hostRows.first?.today, "Unpriced")
        XCTAssertEqual(snapshot.totalRow.monthToDate, "$25")
        XCTAssertEqual(snapshot.totalRow.allTime, "$25")
        XCTAssertEqual(snapshot.menuBarBadgeText, "$25.0")
        XCTAssertTrue(snapshot.partialDataText?.contains("Unpriced usage: MacBook") == true)
    }

    func testMixedHostTotalsAreLowerBoundsAndUnpricedSparklinesAreHidden() throws {
        let snapshot = try loadSnapshot(
            history: [
                row(date: "2026-09-14", cost: 0, tokens: 1_000),
                row(date: "2026-09-14", host: "macmini", cost: 10, tokens: 1_000),
            ],
            today: [
                row(date: "2026-09-15", cost: 0, tokens: 1_000),
                row(date: "2026-09-15", host: "macmini", cost: 5, tokens: 1_000),
            ]
        )

        XCTAssertEqual(snapshot.totalRow.today, "≥$5")
        XCTAssertEqual(snapshot.todayMenuBarBadgeText, "≥5$")
        XCTAssertEqual(snapshot.totalRow.yesterday, "≥$10")
        XCTAssertEqual(snapshot.totalRow.monthToDate, "≥$10")
        XCTAssertEqual(snapshot.menuBarBadgeText, "≥$10.0")
        XCTAssertEqual(snapshot.totalRow.allTime, "≥$10")
        XCTAssertEqual(snapshot.totalRow.sparkline, "—")
        let local = try XCTUnwrap(snapshot.hostRows.first { $0.id == "local" })
        XCTAssertEqual(local.allTime, "Unpriced")
        XCTAssertEqual(local.monthToDate, "Unpriced")
        XCTAssertEqual(local.yesterday, "Unpriced")
        XCTAssertEqual(local.sparkline, "—")
        XCTAssertEqual(snapshot.hostRows.first { $0.id == "macmini" }?.today, "$5")
    }

    func testOldUnpricedHistoryDoesNotMarkCurrentMonthOrTrueZeroUsage() throws {
        let snapshot = try loadSnapshot(
            history: [
                row(date: "2026-08-31", cost: 0, tokens: 1_000),
                row(date: "2026-09-14", cost: 25, tokens: 1_000),
            ],
            today: [row(date: "2026-09-15", cost: 0, tokens: 0)]
        )

        XCTAssertEqual(snapshot.totalRow.allTime, "≥$25")
        XCTAssertEqual(snapshot.totalRow.monthToDate, "$25")
        XCTAssertEqual(snapshot.totalRow.yesterday, "$25")
        XCTAssertEqual(snapshot.totalRow.today, "$0")
        XCTAssertEqual(snapshot.todayMenuBarBadgeText, "0$")
        XCTAssertEqual(snapshot.menuBarBadgeText, "$25.0")
        XCTAssertEqual(snapshot.hostRows.first?.today, "$0")
    }

    private func row(date: String, host: String = "local", cost: Double, tokens: Int) -> [String: Any] {
        ["ledgerGeneration": "pricing-test", "date": date, "host": host,
         "costUSD": cost, "totalTokens": tokens]
    }

    private func loadSnapshot(history: [[String: Any]], today: [[String: Any]]) throws -> CodexUsageSnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosts = Set((history + today).compactMap { $0["host"] as? String }).sorted()
        let monthRows = history.filter { ($0["date"] as? String ?? "") >= "2026-09-01" }
        func total(_ rows: [[String: Any]]) -> Double {
            rows.reduce(0) { $0 + ($1["costUSD"] as? Double ?? 0) }
        }
        let summary: [String: Any] = [
            "ledgerSchemaVersion": 2, "ledgerGeneration": "pricing-test", "rows": history.count,
            "timezone": "America/Los_Angeles", "latestRecordedDate": "2026-09-14",
            "collection": ["expectedHosts": hosts, "historicalFailedHosts": []],
            "monthToDate": ["since": "2026-09-01", "totalCostUSD": total(monthRows),
                            "byHost": hosts.map { host in
                                ["host": host, "totalCostUSD": total(monthRows.filter { $0["host"] as? String == host })]
                            }],
            "latestByHost": [],
            "yesterday": ["date": "2026-09-14", "totalCostUSD": total(history.filter { $0["date"] as? String == "2026-09-14" }),
                          "byHost": history.filter { $0["date"] as? String == "2026-09-14" }],
            "today": ["date": "2026-09-15", "totalCostUSD": total(today), "byHost": today, "unavailableHosts": []],
        ]
        let summaryFile = root.appendingPathComponent("latest-summary.json")
        let ledgerFile = root.appendingPathComponent("ledger.jsonl")
        try JSONSerialization.data(withJSONObject: summary).write(to: summaryFile)
        let ledger = try history.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n")
        try ledger.write(to: ledgerFile, atomically: true, encoding: .utf8)
        return try XCTUnwrap(CodexUsageSnapshot.load(summaryFile: summaryFile, ledgerFile: ledgerFile))
    }
}
