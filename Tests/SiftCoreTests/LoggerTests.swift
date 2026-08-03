import XCTest

@testable import SiftCore

final class LoggerTests: XCTestCase {
    func testAppendsLines() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-log-\(UUID().uuidString)/sift.log").path
        defer {
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        let logger = Logger(path: path)
        logger.log("hello")
        logger.log("world")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello"))
        XCTAssertTrue(contents.contains("world"))
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
    }

    /// Under launchd, stdout is redirected to the log file itself. Echoing
    /// there as well writes each message through a second file descriptor with
    /// its own offset, and the two writers interleave and truncate each other.
    func testDoesNotEchoWhenStdoutIsNotATerminal() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-log-\(UUID().uuidString)/sift.log").path
        defer {
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        let logger = Logger(path: path, echo: false)
        XCTAssertFalse(logger.echo)
        logger.log("MOVE /a/b.png -> /c/b.png")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        // Exactly one copy, and it carries a timestamp.
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("MOVE /a/b.png -> /c/b.png"))
        XCTAssertFalse(lines[0].hasPrefix("MOVE"))
    }

    func testEchoIsExplicitWhenRequested() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-log-\(UUID().uuidString)/sift.log").path
        defer {
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(Logger(path: path, echo: true).echo)
    }
}
