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
        XCTAssertThrowsError(try parseDuration("7x")) { XCTAssertEqual($0 as? DurationError, .badUnit("x")) }
        XCTAssertThrowsError(try parseDuration("abc")) { XCTAssertEqual($0 as? DurationError, .badFormat("abc")) }
    }
}
