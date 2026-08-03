import XCTest

@testable import SiftCore

final class KeepTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        return cal.date(from: comps)!
    }

    // MARK: - Recognition

    func testPlainKeepIsIndefinite() {
        XCTAssertEqual(parseKeepTag(["Sift · Keep"], prefix: "Sift", calendar: cal), .indefinite)
    }

    func testKeepWithColorSuffixIsParsed() {
        XCTAssertEqual(parseKeepTag(["Sift · Keep\n6"], prefix: "Sift", calendar: cal), .indefinite)
    }

    func testRelativeDurationIsParsed() {
        XCTAssertEqual(
            parseKeepTag(["Sift · Keep 30d"], prefix: "Sift", calendar: cal),
            .relative(30 * 86400))
    }

    func testAbsoluteDateIsParsed() {
        let tag = "Sift · Keep until 2026-09-02"
        guard case .until(let d)? = parseKeepTag([tag], prefix: "Sift", calendar: cal) else {
            return XCTFail("expected .until")
        }
        // Inclusive of the named day: expiry sits at the end of Sep 2.
        let comps = cal.dateComponents([.year, .month, .day], from: d)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 2)
        XCTAssertGreaterThan(d, date(2026, 9, 2, 23))
    }

    func testCustomPrefixIsRespected() {
        XCTAssertEqual(parseKeepTag(["Tidy · Keep"], prefix: "Tidy", calendar: cal), .indefinite)
        XCTAssertNil(parseKeepTag(["Tidy · Keep"], prefix: "Sift", calendar: cal))
    }

    func testFirstKeepTagWinsAmongMany() {
        let tags = ["Sift · Keep", "Sift · Keep 30d"]
        XCTAssertEqual(parseKeepTag(tags, prefix: "Sift", calendar: cal), .indefinite)
    }

    // MARK: - Non-matches (must be left alone)

    func testKeepsakesIsNotAKeepTag() {
        XCTAssertNil(parseKeepTag(["Sift · Keepsakes"], prefix: "Sift", calendar: cal))
        XCTAssertFalse(isKeepTag("Sift · Keepsakes", prefix: "Sift"))
    }

    func testCountdownTagIsNotAKeepTag() {
        XCTAssertNil(parseKeepTag(["Sift · 3d → Delete\n7"], prefix: "Sift", calendar: cal))
        XCTAssertFalse(isKeepTag("Sift · 3d → Delete\n7", prefix: "Sift"))
    }

    func testUnrelatedUserTagIsIgnored() {
        XCTAssertNil(parseKeepTag(["Work\n3", "Taxes"], prefix: "Sift", calendar: cal))
    }

    func testEmptyTagListYieldsNil() {
        XCTAssertNil(parseKeepTag([], prefix: "Sift", calendar: cal))
    }

    func testLowercaseKeepIsNotAKeepTag() {
        XCTAssertNil(parseKeepTag(["Sift · keep"], prefix: "Sift", calendar: cal))
    }

    // MARK: - Malformed (must fail safe toward pinning)

    func testUnparseableDurationIsMalformed() {
        XCTAssertEqual(
            parseKeepTag(["Sift · Keep 3x"], prefix: "Sift", calendar: cal), .malformed("3x"))
    }

    func testNaturalLanguageDateIsMalformed() {
        XCTAssertEqual(
            parseKeepTag(["Sift · Keep until Sep 2"], prefix: "Sift", calendar: cal),
            .malformed("until Sep 2"))
    }

    func testUnparseableIsoDateIsMalformed() {
        XCTAssertEqual(
            parseKeepTag(["Sift · Keep until 2026-13-45"], prefix: "Sift", calendar: cal),
            .malformed("until 2026-13-45"))
    }

    // MARK: - isKeepTag

    func testIsKeepTagAcceptsAllKeepForms() {
        for entry in ["Sift · Keep", "Sift · Keep 30d\n6", "Sift · Keep until 2026-09-02"] {
            XCTAssertTrue(isKeepTag(entry, prefix: "Sift"), entry)
        }
    }

    // MARK: - Rendering

    func testKeepTagTextRoundTrips() {
        let expiry = date(2026, 9, 2)
        let text = keepTagText(until: expiry, prefix: "Sift")
        XCTAssertEqual(text, "Sift · Keep until 2026-09-02")
        guard case .until(let parsed)? = parseKeepTag([text], prefix: "Sift", calendar: cal) else {
            return XCTFail("expected .until")
        }
        XCTAssertEqual(
            cal.dateComponents([.year, .month, .day], from: parsed),
            cal.dateComponents([.year, .month, .day], from: expiry))
    }

    // MARK: - Expiry resolution

    func testRelativeResolvesToEndOfTargetDay() {
        let now = date(2026, 8, 3, 9)
        let expiry = keepExpiry(from: .relative(30 * 86400), now: now, calendar: cal)
        let comps = cal.dateComponents([.year, .month, .day], from: expiry!)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 2)
        // Rounded up, so a pin is never cut short.
        XCTAssertGreaterThan(expiry!, now.addingTimeInterval(30 * 86400))
    }

    func testSubDayDurationRoundsUpToEndOfToday() {
        let now = date(2026, 8, 3, 9)
        let expiry = keepExpiry(from: .relative(6 * 3600), now: now, calendar: cal)
        let comps = cal.dateComponents([.year, .month, .day], from: expiry!)
        XCTAssertEqual(comps.day, 3)
        XCTAssertGreaterThan(expiry!, now)
    }

    func testIndefiniteHasNoExpiry() {
        XCTAssertNil(keepExpiry(from: .indefinite, now: date(2026, 8, 3), calendar: cal))
        XCTAssertNil(keepExpiry(from: .malformed("3x"), now: date(2026, 8, 3), calendar: cal))
    }

    // MARK: - Keep OG carve-out

    func testKeepOGIsNotAPin() {
        XCTAssertNil(parseKeepTag(["Sift · Keep OG"], prefix: "Sift", calendar: cal))
        XCTAssertNil(parseKeepTag(["Sift · Keep OG\n6"], prefix: "Sift", calendar: cal))
    }

    func testKeepOGEntryIsSkippedButRealPinStillFound() {
        let tags = ["Sift · Keep OG", "Sift · Keep 30d"]
        XCTAssertEqual(
            parseKeepTag(tags, prefix: "Sift", calendar: cal), .relative(30 * 86400))
    }

    func testIsKeepOGTagMatrix() {
        XCTAssertTrue(isKeepOGTag("Keep OG", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertTrue(isKeepOGTag("Keep OG\n3", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertTrue(isKeepOGTag("Sift · Keep OG", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertTrue(isKeepOGTag("Original", prefix: "Sift", skipTag: "Original"))
        XCTAssertFalse(isKeepOGTag("Keep OG extra", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertFalse(isKeepOGTag("Sift · Keep", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertFalse(isKeepOGTag("Sift · Keepsakes", prefix: "Sift", skipTag: "Keep OG"))
    }

    func testKeepOGStillCountsAsKeepTagForPreservation() {
        XCTAssertTrue(isKeepTag("Sift · Keep OG", prefix: "Sift"))
    }

    // MARK: - Persistent-tag predicate

    func testIsOptimizedTag() {
        XCTAssertTrue(isOptimizedTag("Sift · Optimized", prefix: "Sift"))
        XCTAssertTrue(isOptimizedTag("Sift · Optimized\n2", prefix: "Sift"))
        XCTAssertFalse(isOptimizedTag("Optimized", prefix: "Sift"))
        XCTAssertFalse(isOptimizedTag("Sift · Optimize", prefix: "Sift"))
    }

    func testPersistentSiftTagMatrix() {
        for yes in [
            "Sift · Keep", "Sift · Keep 30d\n6", "Sift · Keep until 2026-09-02",
            "Sift · Keep OG", "Sift · Optimized\n2",
        ] {
            XCTAssertTrue(isPersistentSiftTag(yes, prefix: "Sift"), yes)
        }
        for no in ["Sift · 3d → Delete\n7", "Sift · Delete", "Work", "Sift · Keepsakes"] {
            XCTAssertFalse(isPersistentSiftTag(no, prefix: "Sift"), no)
        }
    }

    func testPinIsActiveOnNamedDayAndLapsesNextDay() {
        let tag = parseKeepTag(["Sift · Keep until 2026-09-02"], prefix: "Sift", calendar: cal)
        guard case .until(let expiry)? = tag else { return XCTFail("expected .until") }
        XCTAssertGreaterThan(expiry, date(2026, 9, 2, 23))
        XCTAssertLessThan(expiry, date(2026, 9, 3, 1))
    }
}
