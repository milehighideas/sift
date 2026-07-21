import XCTest
@testable import SiftCore

final class CLITests: XCTestCase {
    func testParsesDefaults() {
        let a = parseArgs([])
        XCTAssertEqual(a.command, "")
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

    func testBareCommandDoesNotRun() {
        XCTAssertEqual(runCLI([]), 2)
        XCTAssertEqual(runCLI(["bogus"]), 2)
    }

    func testHelpReturnsZero() {
        XCTAssertEqual(runCLI(["--help"]), 0)
    }
}
