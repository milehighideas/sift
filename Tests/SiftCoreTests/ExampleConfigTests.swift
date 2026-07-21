import XCTest
@testable import SiftCore

final class ExampleConfigTests: XCTestCase {
    func testExampleConfigLoads() throws {
        // Test runs from the package root.
        let path = FileManager.default.currentDirectoryPath + "/sift.example.json"
        let cfg = try loadConfig(at: path)
        XCTAssertEqual(cfg.folders.count, 4)
        XCTAssertTrue(cfg.settings.categories.keys.contains("images"))
    }
}
