import XCTest

@testable import SiftCore

final class ReportTests: XCTestCase {
    private func config() -> Config {
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let folder = FolderConfig(
            path: "~/Desktop", ignore: ["Desktop to Review"],
            rules: [
                Rule(
                    name: "Age stale Desktop items", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: "~/Desktop/Desktop to Review", sortInto: "category",
                                onConflict: "rename"))
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: "~/Library/Logs/Sift/sift.log", dryRun: false,
            categories: ["images": ["png"]],
            tagging: Tagging(enabled: true, prefix: "Sift"),
            optimize: OptimizeSettings(enabled: true))
        return Config(settings: settings, folders: [folder])
    }

    private func render(pending: [SiftEvent] = [], history: [SiftEvent] = []) -> String {
        renderReport(
            ReportData(config: config(), pending: pending, history: history),
            generated: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testRendersEmptyStateWithoutCrashing() {
        let html = render()
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("</html>"))
        XCTAssertTrue(html.lowercased().contains("no activity"))
    }

    func testIsSelfContained() {
        let html = render(
            history: [SiftEvent(ts: "2026-08-03T00:00:00Z", kind: .move, path: "/a", to: "/b")])
        // No external assets of any kind — the page must open offline.
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testEscapesHTMLInPaths() {
        let nasty = "/Users/x/Desktop/a&b<c>\"d\".png"
        let html = render(
            history: [SiftEvent(ts: "2026-08-03T00:00:00Z", kind: .optimize, path: nasty)])
        XCTAssertFalse(html.contains("a&b<c>"))
        XCTAssertTrue(html.contains("a&amp;b&lt;c&gt;"))
    }

    func testTotalsSumOptimizeSavings() {
        let html = render(history: [
            SiftEvent(
                ts: "2026-08-03T00:00:02Z", kind: .optimize, path: "/a", before: 1000, after: 400),
            SiftEvent(
                ts: "2026-08-03T00:00:01Z", kind: .optimize, path: "/b", before: 3000, after: 1000),
            SiftEvent(ts: "2026-08-03T00:00:00Z", kind: .move, path: "/c", to: "/d"),
        ])
        // 2 optimized, 2600 bytes reclaimed, 1 move.
        XCTAssertTrue(html.contains(">2<"))
        XCTAssertTrue(html.contains("2.5 KB") || html.contains("2.6 KB"))
    }

    func testPendingSortsByRemainingDaysAscending() throws {
        let html = render(pending: [
            SiftEvent(ts: "t", kind: .pending, path: "/later.png", remainingDays: 6),
            SiftEvent(ts: "t", kind: .pending, path: "/now.png", remainingDays: 0),
            SiftEvent(ts: "t", kind: .pending, path: "/soon.png", remainingDays: 2),
        ])
        let now = try XCTUnwrap(html.range(of: "now.png"))
        let soon = try XCTUnwrap(html.range(of: "soon.png"))
        let later = try XCTUnwrap(html.range(of: "later.png"))
        XCTAssertTrue(now.lowerBound < soon.lowerBound)
        XCTAssertTrue(soon.lowerBound < later.lowerBound)
    }

    func testRendersFoldersAndRules() {
        let html = render()
        XCTAssertTrue(html.contains("~/Desktop"))
        XCTAssertTrue(html.contains("Age stale Desktop items"))
        XCTAssertTrue(html.contains("7d"))
    }

    func testAbbreviatesHomeDirectory() {
        let html = render(
            history: [
                SiftEvent(
                    ts: "2026-08-03T00:00:00Z", kind: .move,
                    path: NSHomeDirectory() + "/Desktop/a.png", to: "/tmp/b.png")
            ])
        XCTAssertTrue(html.contains("~/Desktop/a.png"))
        XCTAssertFalse(html.contains(NSHomeDirectory() + "/Desktop/a.png"))
    }

    func testDisplayStampTrimsFractionalSeconds() {
        XCTAssertEqual(displayStamp("2026-08-03T18:18:49.123Z"), "2026-08-03T18:18:49Z")
        // Already trimmed, or an unexpected shape, passes through unchanged.
        XCTAssertEqual(displayStamp("2026-08-03T18:18:49Z"), "2026-08-03T18:18:49Z")
        XCTAssertEqual(displayStamp("garbage"), "garbage")
    }

    func testActivityShowsTrimmedStamp() {
        let html = render(
            history: [
                SiftEvent(ts: "2026-08-03T18:18:49.123Z", kind: .move, path: "/a", to: "/b")
            ])
        XCTAssertTrue(html.contains("2026-08-03T18:18:49Z"))
        XCTAssertFalse(html.contains(".123"))
    }

    func testFormatBytesScales() {
        XCTAssertEqual(formatBytes(512), "512 B")
        XCTAssertEqual(formatBytes(2048), "2.0 KB")
        XCTAssertEqual(formatBytes(5 * 1024 * 1024), "5.0 MB")
    }
}
