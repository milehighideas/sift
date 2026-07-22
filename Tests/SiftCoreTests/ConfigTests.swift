import XCTest

@testable import SiftCore

final class ConfigTests: XCTestCase {
    private func writeTemp(_ json: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-cfg-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private let valid = """
        {
          "settings": {
            "interval": "1h", "log": "~/Library/Logs/sift.log", "dryRun": false,
            "categories": { "images": ["png"] },
            "tagging": { "enabled": true, "prefix": "Sift" }
          },
          "folders": [
            { "path": "~/Desktop", "recurse": false, "filesOnly": true,
              "ignore": ["Desktop to Review"],
              "rules": [ { "name": "r", "match": "all",
                "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
                "actions": [ { "move": { "to": "~/Desktop/Desktop to Review", "sortInto": "category", "onConflict": "rename" } } ] } ] }
          ]
        }
        """

    func testLoadsValidConfig() throws {
        let cfg = try loadConfig(at: writeTemp(valid))
        XCTAssertEqual(cfg.settings.tagging.prefix, "Sift")
        XCTAssertEqual(cfg.folders.first?.rules.first?.actions.first?.move.sortInto, "category")
    }

    func testRejectsBadInterval() throws {
        let bad = valid.replacingOccurrences(
            of: "\"interval\": \"1h\"", with: "\"interval\": \"nope\"")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }

    func testRejectsUnknownOnConflict() throws {
        let bad = valid.replacingOccurrences(
            of: "\"onConflict\": \"rename\"", with: "\"onConflict\": \"explode\"")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }

    func testRejectsMultipleRules() throws {
        let secondRule = """
            , { "name": "r2", "match": "all",
                "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
                "actions": [ { "move": { "to": "~/Desktop/Desktop to Review", "sortInto": "category", "onConflict": "rename" } } ] }
            """
        let bad = valid.replacingOccurrences(
            of: "\"onConflict\": \"rename\" } } ] } ] }",
            with: "\"onConflict\": \"rename\" } } ] } \(secondRule) ] }")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }

    func testUnreadablePath() {
        XCTAssertThrowsError(try loadConfig(at: "/no/such/sift.json")) {
            XCTAssertEqual($0 as? ConfigError, .unreadable("/no/such/sift.json"))
        }
    }
}
