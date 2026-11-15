import XCTest
@testable import CoffeeBar

final class DurationParserTests: XCTestCase {
    private func minutes(_ s: String) -> Int? {
        DurationParser.parse(s).map { Int($0) / 60 }
    }

    func testValid() {
        XCTAssertEqual(minutes("45"), 45)
        XCTAssertEqual(minutes("90m"), 90)
        XCTAssertEqual(minutes("2h"), 120)
        XCTAssertEqual(minutes("1h30m"), 90)
        XCTAssertEqual(minutes(" 1h 30m "), 90)
        XCTAssertEqual(minutes("1:30"), 90)
        XCTAssertEqual(minutes("1"), 1)
        XCTAssertEqual(minutes("168h"), 168 * 60)
        XCTAssertEqual(minutes("2H"), 120)
    }

    func testInvalid() {
        for s in ["", "0", "-5", "abc", "8d", "1h30", "1:60", "169h", "m", "2m1h", "1h1h", "99999999"] {
            XCTAssertNil(DurationParser.parse(s), "\(s.debugDescription) should be rejected")
        }
    }

    func testFormatting() {
        XCTAssertEqual(DurationParser.hms(5025), "1:23:45")
        XCTAssertEqual(DurationParser.hms(59), "0:00:59")
        XCTAssertEqual(DurationParser.short(45 * 60), "45m")
        XCTAssertEqual(DurationParser.short(7200), "2h")
        XCTAssertEqual(DurationParser.short(3 * 3600 + 15 * 60), "3h 15m")
    }
}
