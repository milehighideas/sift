import XCTest
@testable import SiftCore

final class CLITests: XCTestCase {
    func testParsesDefaults() {
        let a = parseArgs([])
        XCTAssertEqual(a.command, "run")
        XCTAssertFalse(a.dryRun)
        XCTAssertTrue(a.configPath.hasSuffix("/.config/sift/sift.json"))
    }

    func testParsesFlags() {
        let a = parseArgs(["status", "--config", "/tmp/c.json", "--dry-run"])
        XCTAssertEqual(a, ParsedArgs(command: "status", configPath: "/tmp/c.json", dryRun: true))
    }

    func testUnknownConfigReturnsNonZero() {
        XCTAssertNotEqual(runCLI(["run", "--config", "/no/such.json"]), 0)
    }
}
