import XCTest
@testable import SiftCore

final class LoggerTests: XCTestCase {
    func testAppendsLines() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-log-\(UUID().uuidString)/sift.log").path
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let logger = Logger(path: path)
        logger.log("hello")
        logger.log("world")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello"))
        XCTAssertTrue(contents.contains("world"))
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
    }
}
