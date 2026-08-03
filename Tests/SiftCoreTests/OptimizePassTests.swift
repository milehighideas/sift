import XCTest

@testable import SiftCore

final class OptimizePassTests: XCTestCase {
    private var home: URL!
    private var toolsDir: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-optpass-\(UUID().uuidString)")
        toolsDir = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private func config(optimize: OptimizeSettings? = OptimizeSettings(enabled: true)) -> Config {
        let desktop = home.appendingPathComponent("Desktop").path
        let review = home.appendingPathComponent("Desktop/Desktop to Review").path
        let delete = home.appendingPathComponent("Desktop/Desktop to Delete").path
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let live = FolderConfig(
            path: desktop, ignore: ["Desktop to Review", "Desktop to Delete"],
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
            interval: "1h", log: home.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"]],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: optimize)
        return Config(settings: settings, folders: [live, reviewFolder])
    }

    private func stubOptimizer(
        verify: @escaping (URL, URL) -> VerifyResult = { _, _ in .ok }
    ) -> FileOptimizer {
        FileOptimizer(
            name: "stub", extensions: ["png"], toolNames: ["stubtool"],
            arguments: { input, output, _ in [input, output] }, verify: verify)
    }

    private func writeTool(_ script: String) throws -> String {
        let url = toolsDir.appendingPathComponent("stubtool-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private let shrinkScript = #"size=$(wc -c < "$1"); head -c $((size / 2)) "$1" > "$2""#
    private let growScript = #"cat "$1" "$1" > "$2""#
    private let failScript = "exit 1"

    @discardableResult
    private func makeFile(_ rel: String, bytes: Int = 4096) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        try setDateAdded(url.path, to: Date().addingTimeInterval(-3 * 86400))
        return url
    }

    private func runPass(
        tool: String, optimize: OptimizeSettings? = OptimizeSettings(enabled: true),
        verify: @escaping (URL, URL) -> VerifyResult = { _, _ in .ok },
        dryRun: Bool = false, timeout: TimeInterval = 120,
        log: @escaping (String) -> Void = { _ in }
    ) {
        OptimizePass(
            config: config(optimize: optimize), dryRun: dryRun, log: log,
            optimizers: [stubOptimizer(verify: verify)], toolPaths: ["stub": tool],
            timeout: timeout
        ).run()
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    private func tags(_ url: URL) -> [String] { rawTags(of: url.path) }

    private func isMarked(_ url: URL) -> Bool {
        tags(url).contains { $0.hasPrefix("Sift · Optimized") }
    }

    // MARK: - Success path

    func testOptimizesShrinksMarksAndPreservesMetadata() throws {
        let file = try makeFile("Desktop/a.png")
        let originalAdded = try XCTUnwrap(dateAdded(of: file.path))
        try setSiftTag(
            file.path, text: "Sift · 5d → Delete", color: 7, prefix: "Sift",
            preserving: { _ in false })
        var logs: [String] = []
        runPass(tool: try writeTool(shrinkScript), log: { logs.append($0) })

        XCTAssertEqual(size(file), 2048)
        XCTAssertTrue(isMarked(file))
        // Pre-existing tags restored across the replace.
        XCTAssertTrue(tags(file).contains { $0.hasPrefix("Sift · 5d → Delete") })
        // Date Added restored: the aging clock is unaffected by optimization.
        let added = try XCTUnwrap(dateAdded(of: file.path))
        XCTAssertEqual(
            added.timeIntervalSince1970, originalAdded.timeIntervalSince1970, accuracy: 2)
        XCTAssertTrue(logs.contains { $0.hasPrefix("OPT ") })
    }

    func testMarkedFileIsSkippedWithoutRunningTool() throws {
        let file = try makeFile("Desktop/a.png")
        try addSiftTag(file.path, text: "Sift · Optimized", color: 2)
        // A tool that would fail loudly if it were invoked at all.
        runPass(tool: try writeTool(failScript))
        XCTAssertEqual(size(file), 4096)
    }

    func testKeepOGSkipsBareAndNamespaced() throws {
        for (index, tag) in ["Keep OG", "Sift · Keep OG"].enumerated() {
            let file = try makeFile("Desktop/og\(index).png")
            try addSiftTag(file.path, text: tag, color: 3)
            var logs: [String] = []
            runPass(tool: try writeTool(shrinkScript), log: { logs.append($0) })
            XCTAssertEqual(size(file), 4096, tag)
            XCTAssertFalse(isMarked(file), tag)
            XCTAssertTrue(logs.contains { $0.hasPrefix("SKIP") }, tag)
        }
    }

    func testCustomSkipTagIsHonored() throws {
        let file = try makeFile("Desktop/a.png")
        try addSiftTag(file.path, text: "Original", color: 3)
        runPass(
            tool: try writeTool(shrinkScript),
            optimize: OptimizeSettings(enabled: true, skipTag: "Original"))
        XCTAssertEqual(size(file), 4096)
    }

    // MARK: - Failure paths (original untouched, marker withheld)

    func testToolFailureLeavesOriginalUnmarked() throws {
        let file = try makeFile("Desktop/a.png")
        var logs: [String] = []
        runPass(tool: try writeTool(failScript), log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(isMarked(file))
        XCTAssertTrue(logs.contains { $0.hasPrefix("ERROR optimize ") })
    }

    func testTimeoutLeavesOriginalUnmarked() throws {
        let file = try makeFile("Desktop/a.png")
        var logs: [String] = []
        runPass(tool: try writeTool("sleep 30"), timeout: 0.5, log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(isMarked(file))
        XCTAssertTrue(logs.contains { $0.contains("timeout") })
    }

    func testNotSmallerMarksWithoutReplacing() throws {
        let file = try makeFile("Desktop/a.png")
        runPass(tool: try writeTool(growScript))
        XCTAssertEqual(size(file), 4096)
        XCTAssertTrue(isMarked(file))
    }

    func testUnreadableOriginalSkippedWithoutMarker() throws {
        let file = try makeFile("Desktop/a.png")
        runPass(tool: try writeTool(shrinkScript), verify: { _, _ in .originalUnreadable })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(isMarked(file))
    }

    func testInvalidCandidateLeavesOriginalUnmarked() throws {
        let file = try makeFile("Desktop/a.png")
        var logs: [String] = []
        runPass(
            tool: try writeTool(shrinkScript), verify: { _, _ in .candidateInvalid },
            log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(isMarked(file))
        XCTAssertTrue(logs.contains { $0.hasPrefix("ERROR verify ") })
    }

    func testNoTempFilesLeftBehind() throws {
        try makeFile("Desktop/a.png")
        try makeFile("Desktop/b.png")
        runPass(tool: try writeTool(failScript))
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: home.appendingPathComponent("Desktop").path
        ).filter { $0.contains(".sift-opt-") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Walk

    func testWalksReviewAndDeleteCategorySubfolders() throws {
        let inReview = try makeFile("Desktop/Desktop to Review/Images/a.png")
        let inDelete = try makeFile("Desktop/Desktop to Delete/Images/b.png")
        runPass(tool: try writeTool(shrinkScript))
        XCTAssertEqual(size(inReview), 2048)
        XCTAssertEqual(size(inDelete), 2048)
    }

    func testDoesNotEnterUserFolders() throws {
        let nested = try makeFile("Desktop/vacation/photo.png")
        runPass(tool: try writeTool(shrinkScript))
        // A user folder is opaque — same invariant the aging pass honours.
        XCTAssertEqual(size(nested), 4096)
    }

    func testSkipsNonCandidateExtensions() throws {
        let txt = try makeFile("Desktop/notes.txt")
        let partial = try makeFile("Desktop/photo.png.crdownload")
        runPass(tool: try writeTool(shrinkScript))
        XCTAssertEqual(size(txt), 4096)
        XCTAssertEqual(size(partial), 4096)
    }

    // MARK: - Modes

    func testDisabledDoesNothing() throws {
        let file = try makeFile("Desktop/a.png")
        runPass(tool: try writeTool(shrinkScript), optimize: OptimizeSettings(enabled: false))
        XCTAssertEqual(size(file), 4096)
        runPass(tool: try writeTool(shrinkScript), optimize: nil)
        XCTAssertEqual(size(file), 4096)
    }

    func testDryRunLogsButChangesNothing() throws {
        let file = try makeFile("Desktop/a.png")
        var logs: [String] = []
        runPass(tool: try writeTool(shrinkScript), dryRun: true, log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(isMarked(file))
        XCTAssertTrue(logs.contains { $0.hasPrefix("DRY optimize ") })
    }

    func testMissingToolLogsOnceAndSkips() throws {
        let file = try makeFile("Desktop/a.png")
        var logs: [String] = []
        OptimizePass(
            config: config(), dryRun: false, log: { logs.append($0) },
            optimizers: [stubOptimizer()], toolPaths: [:], timeout: 5
        ).run()
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(isMarked(file))
        XCTAssertEqual(logs.filter { $0.hasPrefix("SKIP no optimizer") }.count, 1)
    }

    // MARK: - Integration with the real tool

    func testRealOxipngRoundTrip() throws {
        let oxipng = findTool(named: "oxipng", searchDirs: defaultToolSearchDirs())
        try XCTSkipIf(oxipng == nil, "oxipng not installed")
        let file = home.appendingPathComponent("Desktop/real.png")
        try OptimizeTests.writePNG(to: file, width: 64, height: 64)
        try setDateAdded(file.path, to: Date().addingTimeInterval(-3 * 86400))
        let before = size(file)
        OptimizePass(
            config: config(), dryRun: false, log: { _ in },
            optimizers: imageOptimizers, toolPaths: ["png": oxipng!], timeout: 120
        ).run()
        XCTAssertLessThanOrEqual(size(file), before)
        XCTAssertTrue(isMarked(file))
        // Still a valid, complete PNG afterward.
        XCTAssertEqual(verifyImage(original: file, candidate: file), .ok)
    }
}
