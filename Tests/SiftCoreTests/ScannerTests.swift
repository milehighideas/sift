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

    private func config(base: URL? = nil) -> Config {
        let root = base ?? home!
        let desktop = root.appendingPathComponent("Desktop").path
        let review = root.appendingPathComponent("Desktop/Desktop to Review").path
        let delete = root.appendingPathComponent("Desktop/Desktop to Delete").path
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let live = FolderConfig(
            path: desktop,
            ignore: ["Desktop to Review", "Desktop to Delete"],
            rules: [
                Rule(
                    name: "toReview", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(to: review, sortInto: "category", onConflict: "rename")
                        )
                    ])
            ])
        let reviewFolder = FolderConfig(
            path: review, ignore: nil,
            rules: [
                Rule(
                    name: "toDelete", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(to: delete, sortInto: "category", onConflict: "rename")
                        )
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: root.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"], "documents": ["rtfd", "txt", "pdf"]],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
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
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: movedDir.appendingPathComponent("readme.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/myproj").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(
                    "Desktop/Desktop to Review/Documents/readme.txt"
                ).path))
    }

    func testBundleCategorizedByExtensionAndKeptIntact() throws {
        _ = try makeDir("Desktop/notes.rtfd", child: "TXT.rtf", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let moved = home.appendingPathComponent("Desktop/Desktop to Review/Documents/notes.rtfd")
        // Bundle categorized by its extension and moved whole.
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moved.appendingPathComponent("TXT.rtf").path))
        // Its internals were NOT ripped out into the Documents root.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/Desktop to Review/Documents/TXT.rtf")
                    .path))
    }

    // MARK: - Log rotation config (dogfood)

    /// The shipped log-rotation entry is pure config; this locks the engine
    /// behavior it relies on: flat move (sortInto none), terminal tag, the
    /// Archive destination ignored as an item, and rename-on-conflict for the
    /// second rotation.
    func testLogRotationConfigMovesOldLogFlatIntoArchive() throws {
        let logs = home.appendingPathComponent("Logs")
        let archive = logs.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try setDateAdded(archive.path, to: Date().addingTimeInterval(-30 * 86400))
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let rotation = FolderConfig(
            path: logs.path, ignore: ["Archive"],
            rules: [
                Rule(
                    name: "rotate", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: archive.path, sortInto: "none", onConflict: "rename"))
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: logs.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"]],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        let cfg = Config(settings: settings, folders: [rotation])

        let live = logs.appendingPathComponent("sift.log")
        try "old log content".write(to: live, atomically: true, encoding: .utf8)
        try setDateAdded(live.path, to: Date().addingTimeInterval(-10 * 86400))

        Scanner(config: cfg, now: Date(), dryRun: false, log: { _ in }).run()

        // Rotated: gone from the live path, flat in Archive (not Other/).
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        let archived = archive.appendingPathComponent("sift.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: archive.appendingPathComponent("Other/sift.log").path))
        // Terminal tag, and the Archive folder was not aged into itself.
        XCTAssertTrue(rawTags(of: archived.path).contains { $0.hasPrefix("Sift · Archive") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // A second rotation renames rather than replacing.
        try "newer log content".write(to: live, atomically: true, encoding: .utf8)
        try setDateAdded(live.path, to: Date().addingTimeInterval(-10 * 86400))
        Scanner(config: cfg, now: Date(), dryRun: false, log: { _ in }).run()
        let archivedFiles = try FileManager.default.contentsOfDirectory(atPath: archive.path)
        XCTAssertEqual(archivedFiles.count, 2)
        XCTAssertEqual(try String(contentsOf: archived, encoding: .utf8), "old log content")
    }

    // MARK: - Path normalization regression

    /// `NSString.standardizingPath` resolves symlinks — including stripping a
    /// `/private` prefix — but only for paths that already exist. A `/private/…`
    /// config path therefore normalized one way while the destination folder was
    /// missing and another way once Sift created it mid-run, so the Review stage
    /// stopped recognizing its own destination. The category folder was aged as
    /// an item and the files inside it were never seen.
    func testReviewDescentSurvivesCategoryFolderCreatedThisRun() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sift-private-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let file = desktop.appendingPathComponent("old.png")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try setDateAdded(file.path, to: Date().addingTimeInterval(-10 * 86400))

        Scanner(config: config(base: root), now: Date(), dryRun: false, log: { _ in }).run()

        // The file lands in the category folder and gets the countdown itself.
        let moved = desktop.appendingPathComponent("Desktop to Review/Images/old.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(rawTags(of: moved.path).contains { $0.hasPrefix("Sift · 7d → Delete") })
        // The category folder is Sift's own scaffolding — never an aged item.
        let category = desktop.appendingPathComponent("Desktop to Review/Images")
        XCTAssertFalse(rawTags(of: category.path).contains { $0.hasPrefix("Sift · ") })
    }

    // MARK: - Keep pin

    private func pin(_ path: String, _ text: String) throws {
        try setSiftTag(path, text: text, color: 6, prefix: "Sift", preserving: { _ in false })
    }

    private func isoDay(offsetDays: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date().addingTimeInterval(Double(offsetDays) * 86400))
    }

    func testPinnedFileStaysInLiveFolder() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/Desktop to Review/Images/old.png").path
            ))
    }

    func testPinnedFileDoesNotAdvanceReviewToDelete() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/Desktop to Delete/Images/old.png").path
            ))
    }

    func testPinnedFolderStaysIntact() throws {
        let path = try makeDir("Desktop/myproj", child: "readme.txt", addedDaysAgo: 10)
        try pin(path, "Sift · Keep")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path + "/readme.txt"))
    }

    func testPinnedItemLosesStaleCountdownTag() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 1)
        try setSiftTag(
            path, text: "Sift · 6d → Delete", color: 7, prefix: "Sift", preserving: { _ in false })
        try setSiftTag(
            path, text: "Sift · Keep", color: 6, prefix: "Sift",
            preserving: { !isKeepTag($0, prefix: "Sift") })
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Keep") })
        XCTAssertFalse(tags.contains { $0.contains("→ Delete") })
    }

    func testRelativePinNormalizesToAbsoluteDateOnce() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep 30d")

        var logs: [String] = []
        Scanner(config: config(), now: Date(), dryRun: false, log: { logs.append($0) }).run()
        let expected = "Sift · Keep until \(isoDay(offsetDays: 30))"
        XCTAssertTrue(rawTags(of: path).contains { $0.hasPrefix(expected) })
        XCTAssertTrue(logs.contains { $0.hasPrefix("KEEP ") })

        // Already absolute: the second pass must not write again.
        logs.removeAll()
        Scanner(config: config(), now: Date(), dryRun: false, log: { logs.append($0) }).run()
        XCTAssertTrue(rawTags(of: path).contains { $0.hasPrefix(expected) })
        XCTAssertFalse(logs.contains { $0.hasPrefix("KEEP ") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testFuturePinIsHonoured() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep until \(isoDay(offsetDays: 5))")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testMalformedPinStaysAndNormalizesToIndefinite() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep 3x")
        var logs: [String] = []
        Scanner(config: config(), now: Date(), dryRun: false, log: { logs.append($0) }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Keep\n") || $0 == "Sift · Keep" })
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · Keep 3x") })
        XCTAssertTrue(logs.contains { $0.hasPrefix("WARN unparseable keep tag") })
    }

    func testExpiredPinClearsTagRestampsAndDoesNotMoveThatPass() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep until \(isoDay(offsetDays: -2))")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()

        // Still in Review — the lapse hands it a fresh countdown, not a move.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/Desktop to Delete/Images/old.png").path
            ))
        let tags = rawTags(of: path)
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · Keep") })
        let added = try XCTUnwrap(dateAdded(of: path))
        XCTAssertLessThan(abs(added.timeIntervalSinceNow), 5)
    }

    func testExpiredPinGetsFreshCountdownOnNextPass() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep until \(isoDay(offsetDays: -2))")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(rawTags(of: path).contains { $0.hasPrefix("Sift · 7d → Delete") })
    }

    func testKeepsakesTagIsNotAPinAndAgesNormally() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keepsakes")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/Desktop to Review/Images/old.png").path
            ))
    }

    func testKeepOGTaggedFileAgesNormally() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep OG")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        // Keep OG is not a pin: the file moves, and the tag survives the move.
        let moved = home.appendingPathComponent("Desktop/Desktop to Review/Images/old.png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertTrue(rawTags(of: moved).contains { $0.hasPrefix("Sift · Keep OG") })
    }

    func testOptimizedMarkerSurvivesPinRetirement() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try setSiftTag(
            path, text: "Sift · Keep until \(isoDay(offsetDays: -2))", color: 6,
            prefix: "Sift", preserving: { isPersistentSiftTag($0, prefix: "Sift") })
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        // Pin retired (tag gone, clock restamped) but the marker survives.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let tags = rawTags(of: path)
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · Keep") })
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testOptimizedMarkerSurvivesPinNormalization() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try setSiftTag(
            path, text: "Sift · Keep 30d", color: 6, prefix: "Sift",
            preserving: { isPersistentSiftTag($0, prefix: "Sift") })
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Keep until") })
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testPinnedFileWithMarkerIsSteadyState() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 1)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try setSiftTag(
            path, text: "Sift · Keep", color: 6, prefix: "Sift",
            preserving: { isPersistentSiftTag($0, prefix: "Sift") })
        var logs: [String] = []
        Scanner(config: config(), now: Date(), dryRun: false, log: { logs.append($0) }).run()
        // The marker must not be mistaken for a stale countdown: no writes.
        XCTAssertFalse(logs.contains { $0.hasPrefix("UNTAG") })
        XCTAssertTrue(rawTags(of: path).contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testCountdownRewriteKeepsOptimizedMarker() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 1)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · 6d → Delete") })
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testDryRunLeavesPinTagsAndClockUntouched() throws {
        let relative = try makeFile("Desktop/a.png", addedDaysAgo: 10)
        try pin(relative, "Sift · Keep 30d")
        let expired = try makeFile("Desktop/b.png", addedDaysAgo: 10)
        try pin(expired, "Sift · Keep until \(isoDay(offsetDays: -2))")
        let before = try XCTUnwrap(dateAdded(of: expired))

        var logs: [String] = []
        Scanner(config: config(), now: Date(), dryRun: true, log: { logs.append($0) }).run()

        XCTAssertTrue(rawTags(of: relative).contains { $0.hasPrefix("Sift · Keep 30d") })
        XCTAssertTrue(rawTags(of: expired).contains { $0.hasPrefix("Sift · Keep until") })
        let after = try XCTUnwrap(dateAdded(of: expired))
        XCTAssertEqual(before.timeIntervalSince1970, after.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(logs.contains { $0.hasPrefix("DRY normalize") })
        XCTAssertTrue(logs.contains { $0.hasPrefix("DRY expire") })
    }

    func testReviewFolderDoesNotDescendIntoUserFolder() throws {
        // A user folder sitting inside a Review category subfolder must be aged
        // as a whole unit, never walked into.
        _ = try makeDir(
            "Desktop/Desktop to Review/Folders/project", child: "a.txt", addedDaysAgo: 10)
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        let movedDir = home.appendingPathComponent("Desktop/Desktop to Delete/Folders/project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDir.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: movedDir.appendingPathComponent("a.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("Desktop/Desktop to Delete/Documents/a.txt")
                    .path))
    }
}
