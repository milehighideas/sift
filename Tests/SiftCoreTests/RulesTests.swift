import XCTest

@testable import SiftCore

final class RulesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let week: TimeInterval = 604800

    func testIsOlderThan() {
        XCTAssertTrue(
            isOlderThan(dateAdded: now.addingTimeInterval(-week - 1), threshold: week, now: now))
        XCTAssertFalse(
            isOlderThan(dateAdded: now.addingTimeInterval(-week + 1), threshold: week, now: now))
    }

    func testRemainingDays() {
        XCTAssertEqual(remainingDays(dateAdded: now, threshold: week, now: now), 7)
        XCTAssertEqual(
            remainingDays(
                dateAdded: now.addingTimeInterval(-6.5 * 86400), threshold: week, now: now), 1)
        XCTAssertEqual(
            remainingDays(dateAdded: now.addingTimeInterval(-week), threshold: week, now: now), 0)
        XCTAssertEqual(
            remainingDays(dateAdded: now.addingTimeInterval(-8 * 86400), threshold: week, now: now),
            0)
    }

    func testRemainingDaysClampsFutureDateAdded() {
        // Restamp round-trip can leave dateAdded a hair above now; elapsed must clamp to 0.
        XCTAssertEqual(
            remainingDays(dateAdded: now.addingTimeInterval(0.5), threshold: week, now: now), 7)
    }

    func testRuleMatchesAll() throws {
        let rule = Rule(
            name: "r", match: "all",
            conditions: [Condition(attr: "date_added", op: "older_than", value: "7d")],
            actions: [])
        XCTAssertTrue(
            try ruleMatches(rule, dateAdded: now.addingTimeInterval(-8 * 86400), now: now))
        XCTAssertFalse(try ruleMatches(rule, dateAdded: now, now: now))
    }
}
