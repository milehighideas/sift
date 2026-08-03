import XCTest

@testable import SiftCore

final class ExampleConfigTests: XCTestCase {
    func testExampleConfigLoads() throws {
        // Test runs from the package root.
        let path = FileManager.default.currentDirectoryPath + "/sift.example.json"
        let cfg = try loadConfig(at: path)
        XCTAssertEqual(cfg.folders.count, 5)
        XCTAssertTrue(cfg.settings.categories.keys.contains("images"))

        // The shipped example dogfoods log rotation: the log folder is watched,
        // and the log's own directory never appears in WatchPaths (loop guard).
        let rotation = cfg.folders.first { $0.path.hasSuffix("Logs/Sift") }
        XCTAssertNotNil(rotation)
        XCTAssertEqual(rotation?.ignore, ["Archive"])
        XCTAssertEqual(rotation?.rules.first?.actions.first?.move.sortInto, "none")
        XCTAssertFalse(watchPaths(for: cfg).contains { $0.hasSuffix("Logs/Sift") })
    }
}
