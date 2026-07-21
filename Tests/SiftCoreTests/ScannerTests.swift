import XCTest
@testable import SiftCore

final class ScannerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func config() -> Config {
        let desktop = home.appendingPathComponent("Desktop").path
        let review = home.appendingPathComponent("Desktop/Desktop to Review").path
        let delete = home.appendingPathComponent("Desktop/Desktop to Delete").path
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let live = FolderConfig(
            path: desktop, recurse: false, filesOnly: true,
            ignore: ["Desktop to Review", "Desktop to Delete"],
            rules: [Rule(name: "toReview", match: "all", conditions: [cond],
                actions: [Action(move: MoveAction(to: review, sortInto: "category", onConflict: "rename"))])])
        let reviewFolder = FolderConfig(
            path: review, recurse: true, filesOnly: true, ignore: nil,
            rules: [Rule(name: "toDelete", match: "all", conditions: [cond],
                actions: [Action(move: MoveAction(to: delete, sortInto: "category", onConflict: "rename"))])])
        let settings = Settings(interval: "1h", log: home.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"]], tagging: Tagging(enabled: true, prefix: "Sift"))
        return Config(settings: settings, folders: [live, reviewFolder])
    }

    private func makeFile(_ rel: String, addedDaysAgo days: Double) throws -> String {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try setDateAdded(url.path, to: Date().addingTimeInterval(-days * 86400))
        return url.path
    }

    func testStaleFileMovesToReviewCategoryAndReStamps() throws {
        _ = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let moved = home.appendingPathComponent("Desktop/Desktop to Review/Images/old.png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        // Date Added re-stamped to ~now, so the second window restarts.
        let added = try XCTUnwrap(dateAdded(of: moved))
        XCTAssertLessThan(abs(added.timeIntervalSinceNow), 5)
        // Tagged with a countdown toward Delete.
        XCTAssertTrue(rawTags(of: moved).contains { $0.hasPrefix("Sift · 7d → Delete") })
    }

    func testFreshFileStays() throws {
        let path = try makeFile("Desktop/new.png", addedDaysAgo: 1)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testDryRunChangesNothing() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: true, log: { _ in }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSecondRunIsIdempotent() throws {
        _ = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let review = home.appendingPathComponent("Desktop/Desktop to Review/Images/old.png").path
        let delete = home.appendingPathComponent("Desktop/Desktop to Delete/Images/old.png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: review))
        XCTAssertFalse(FileManager.default.fileExists(atPath: delete))
    }

    func testReviewFileAgesToDeleteWithTerminalTag() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let moved = home.appendingPathComponent("Desktop/Desktop to Delete/Images/old.png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertTrue(rawTags(of: moved).contains { $0.hasPrefix("Sift · Delete") })
    }
}
