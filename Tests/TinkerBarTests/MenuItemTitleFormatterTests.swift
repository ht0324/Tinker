import XCTest
@testable import TinkerBar

final class MenuItemTitleFormatterTests: XCTestCase {
    func testShortTitleRemainsUnchanged() {
        XCTAssertEqual(
            MenuItemTitleFormatter.string(from: "Tasks reloaded."),
            "Tasks reloaded."
        )
    }

    func testLongTitleIsCappedWithEllipsis() {
        let title = MenuItemTitleFormatter.string(
            from: "Failed to collect local usage for today so far: 2026-07-17"
        )

        XCTAssertEqual(title, "Failed to collect local usage…")
    }

    func testWhitespaceIsCollapsedOntoOneLine() {
        XCTAssertEqual(
            MenuItemTitleFormatter.string(from: "  First line\n\tsecond line  "),
            "First line second line"
        )
    }
}
