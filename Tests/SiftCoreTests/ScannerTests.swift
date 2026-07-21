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
            path: desktop,
            ignore: ["Desktop to Review", "Desktop to Delete"],
            rules: [Rule(name: "toReview", match: "all", conditions: [cond],
                actions: [Action(move: MoveAction(to: review, sortInto: "category", onConflict: "rename"))])])
        let reviewFolder = FolderConfig(
            path: review, ignore: nil,
            rules: [Rule(name: "toDelete", match: "all", conditions: [cond],
                actions: [Action(move: MoveAction(to: delete, sortInto: "category", onConflict: "rename"))])])
        let settings = Settings(interval: "1h", log: home.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"], "documents": ["rtfd", "txt", "pdf"]],
            tagging: Tagging(enabled: true, prefix: "Sift"))
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

    /// Creates a directory (or bundle) containing one child file and backdates
    /// the directory's own Date Added.
    private func makeDir(_ rel: String, child: String, addedDaysAgo days: Double) throws -> String {
        let dir = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "inner".write(to: dir.appendingPathComponent(child), atomically: true, encoding: .utf8)
        try setDateAdded(dir.path, to: Date().addingTimeInterval(-days * 86400))
        return dir.path
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

    func testFolderMovedIntactAsUnit() throws {
        _ = try makeDir("Desktop/myproj", child: "readme.txt", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let movedDir = home.appendingPathComponent("Desktop/Desktop to Review/Folders/myproj")
        // Whole folder moved into the Folders category.
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDir.path))
        // Its child moved WITH it — not extracted/flattened into a category root.
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDir.appendingPathComponent("readme.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Desktop/myproj").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Desktop/Desktop to Review/Documents/readme.txt").path))
    }

    func testBundleCategorizedByExtensionAndKeptIntact() throws {
        _ = try makeDir("Desktop/notes.rtfd", child: "TXT.rtf", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let moved = home.appendingPathComponent("Desktop/Desktop to Review/Documents/notes.rtfd")
        // Bundle categorized by its extension and moved whole.
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("TXT.rtf").path))
        // Its internals were NOT ripped out into the Documents root.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Desktop/Desktop to Review/Documents/TXT.rtf").path))
    }

    func testReviewFolderDoesNotDescendIntoUserFolder() throws {
        // A user folder sitting inside a Review category subfolder must be aged
        // as a whole unit, never walked into.
        _ = try makeDir("Desktop/Desktop to Review/Folders/project", child: "a.txt", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let movedDir = home.appendingPathComponent("Desktop/Desktop to Delete/Folders/project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDir.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Desktop/Desktop to Delete/Documents/a.txt").path))
    }
}
