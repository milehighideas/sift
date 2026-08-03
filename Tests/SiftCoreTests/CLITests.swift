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

    // MARK: - Event log wiring

    /// Builds a throwaway config whose log (and therefore event log) lives in a
    /// temp directory, runs a command, and returns the event-log contents.
    private func runWithTempConfig(_ argv: [String], stale: Bool) throws -> (
        events: String?, dir: URL
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-cli-\(UUID().uuidString)")
        let desktop = dir.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let file = desktop.appendingPathComponent("old.png")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        if stale {
            try setDateAdded(file.path, to: Date().addingTimeInterval(-10 * 86400))
        }
        let json = """
            {
              "settings": {
                "interval": "1h", "log": "\(dir.path)/Logs/sift.log", "dryRun": false,
                "categories": { "images": ["png"] },
                "tagging": { "enabled": true, "prefix": "Sift" }
              },
              "folders": [
                { "path": "\(desktop.path)", "ignore": ["Desktop to Review"],
                  "rules": [ { "name": "r", "match": "all",
                    "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
                    "actions": [ { "move": { "to": "\(desktop.path)/Desktop to Review", "sortInto": "category", "onConflict": "rename" } } ] } ] }
              ]
            }
            """
        let configPath = dir.appendingPathComponent("sift.json").path
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(runCLI(argv + ["--config", configPath]), 0)
        let eventsPath = dir.appendingPathComponent("Logs/events.jsonl").path
        return (try? String(contentsOfFile: eventsPath, encoding: .utf8), dir)
    }

    func testRunWritesEventLog() throws {
        let (events, dir) = try runWithTempConfig(["run"], stale: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let contents = try XCTUnwrap(events)
        XCTAssertTrue(contents.contains("\"kind\":\"move\""))
        XCTAssertFalse(contents.contains("\"pending\""))
    }

    func testStatusWritesNoEventLog() throws {
        let (events, dir) = try runWithTempConfig(["status"], stale: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(events)
    }

    func testDryRunWritesNoEventLog() throws {
        let (events, dir) = try runWithTempConfig(["run", "--dry-run"], stale: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(events)
    }
}
