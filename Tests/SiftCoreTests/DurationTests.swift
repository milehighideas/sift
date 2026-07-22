import XCTest

@testable import SiftCore

final class DurationTests: XCTestCase {
    func testParsesUnits() throws {
        XCTAssertEqual(try parseDuration("90s"), 90)
        XCTAssertEqual(try parseDuration("30m"), 1800)
        XCTAssertEqual(try parseDuration("1h"), 3600)
        XCTAssertEqual(try parseDuration("7d"), 604800)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try parseDuration("")) { XCTAssertEqual($0 as? DurationError, .empty) }
        XCTAssertThrowsError(try parseDuration("7x")) {
            XCTAssertEqual($0 as? DurationError, .badUnit("x"))
        }
        XCTAssertThrowsError(try parseDuration("abc")) {
            XCTAssertEqual($0 as? DurationError, .badFormat("abc"))
        }
    }

    func testRejectsNonFiniteAndNegativeDurations() {
        XCTAssertThrowsError(try parseDuration("-5d")) {
            XCTAssertEqual($0 as? DurationError, .badFormat("-5d"))
        }
        XCTAssertThrowsError(try parseDuration("infd")) {
            XCTAssertEqual($0 as? DurationError, .badFormat("infd"))
        }
        XCTAssertThrowsError(try parseDuration("nand")) {
            XCTAssertEqual($0 as? DurationError, .badFormat("nand"))
        }
    }
}
