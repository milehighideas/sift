import XCTest
@testable import SiftCore

final class ActionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-act-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMovesAndCreatesDir() throws {
        let src = try makeFile("a.png", in: root)
        let dstDir = root.appendingPathComponent("Review/Images")
        let out = try XCTUnwrap(try performMove(src: src, toDir: dstDir, onConflict: "rename"))
        XCTAssertEqual(out.lastPathComponent, "a.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
    }

    func testRenameOnConflict() throws {
        let dstDir = root.appendingPathComponent("Review")
        _ = try makeFile("a.png", in: dstDir)
        let src = try makeFile("a.png", in: root)
        let out = try XCTUnwrap(try performMove(src: src, toDir: dstDir, onConflict: "rename"))
        XCTAssertEqual(out.lastPathComponent, "a 2.png")
    }

    func testSkipOnConflict() throws {
        let dstDir = root.appendingPathComponent("Review")
        _ = try makeFile("a.png", in: dstDir)
        let src = try makeFile("a.png", in: root)
        XCTAssertNil(try performMove(src: src, toDir: dstDir, onConflict: "skip"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testReplaceOnConflict() throws {
        let dstDir = root.appendingPathComponent("Review")
        let existing = try makeFile("a.png", in: dstDir)
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let srcDir = root.appendingPathComponent("Incoming")
        let src = try makeFile("a.png", in: srcDir)
        try "new".write(to: src, atomically: true, encoding: .utf8)
        let out = try XCTUnwrap(try performMove(src: src, toDir: dstDir, onConflict: "replace"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let contents = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(contents, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
    }

    func testUniqueDestinationExtensionless() throws {
        let dir = root.appendingPathComponent("Extensionless")
        let existing = try makeFile("README", in: dir)
        let candidate = uniqueDestination(existing)
        XCTAssertEqual(candidate.lastPathComponent, "README 2")
    }
}
