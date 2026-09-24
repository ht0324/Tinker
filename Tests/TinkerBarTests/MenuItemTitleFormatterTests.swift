import XCTest
@testable import TinkerBar

final class MenuItemTitleFormatterTests: XCTestCase {
    func testTitlesFitOnOneMenuLine() {
        for (input, expected) in [
            ("Failed to collect local usage for today so far: 2026-07-17", "Failed to collect local usage…"),
            ("  First line\n\tsecond line  ", "First line second line"),
        ] {
            XCTAssertEqual(MenuItemTitleFormatter.string(from: input), expected, input)
        }
    }
}
