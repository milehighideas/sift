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

    // MARK: - optimize block

    /// The deployed config predates this feature and has no optimize block; it
    /// must keep decoding and validating untouched.
    func testConfigWithoutOptimizeBlockDecodesAndValidates() throws {
        let config = try loadConfig(at: writeTemp(valid))
        XCTAssertNil(config.settings.optimize)
    }

    func testOptimizeBlockDecodes() throws {
        let withOpt = valid.replacingOccurrences(
            of: "\"tagging\":",
            with: "\"optimize\": { \"enabled\": true, \"skipTag\": \"Keep OG\", \"level\": 2 },\n"
                + "    \"tagging\":")
        let config = try loadConfig(at: writeTemp(withOpt))
        let opt = try XCTUnwrap(config.settings.optimize)
        XCTAssertTrue(opt.enabled)
        XCTAssertEqual(opt.skipTag, "Keep OG")
        XCTAssertEqual(opt.level, 2)
    }

    func testOptimizeRejectsBadLevel() throws {
        let bad = valid.replacingOccurrences(
            of: "\"tagging\":",
            with: "\"optimize\": { \"enabled\": true, \"level\": 9 },\n    \"tagging\":")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }

    func testOptimizeRejectsEmptySkipTag() throws {
        let bad = valid.replacingOccurrences(
            of: "\"tagging\":",
            with: "\"optimize\": { \"enabled\": true, \"skipTag\": \"\" },\n    \"tagging\":")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }

    // MARK: - standardizePath

    /// The property the whole scan depends on: the same config string must
    /// normalize identically whether or not the path exists yet. Sift creates
    /// its destination folders mid-run, so an existence-sensitive normalizer
    /// silently changes a folder's identity partway through a pass.
    func testStandardizeIsIndependentOfExistence() throws {
        let path = "/private/tmp/sift-exists-\(UUID().uuidString)/Desktop to Review"
        let before = standardizePath(path)
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertEqual(before, standardizePath(path))
    }

    func testStandardizeDoesNotResolveSymlinks() {
        // /tmp is a symlink to /private/tmp; both spellings must survive as written.
        XCTAssertEqual(standardizePath("/private/tmp/x"), "/private/tmp/x")
        XCTAssertEqual(standardizePath("/tmp/x"), "/tmp/x")
    }

    func testStandardizeResolvesDotSegmentsAndSeparators() {
        XCTAssertEqual(standardizePath("/a/b/../c"), "/a/c")
        XCTAssertEqual(standardizePath("/a/./b"), "/a/b")
        XCTAssertEqual(standardizePath("/a//b/"), "/a/b")
        XCTAssertEqual(standardizePath("/a/b/.."), "/a")
        XCTAssertEqual(standardizePath("/"), "/")
        XCTAssertEqual(standardizePath("/.."), "/")
    }

    func testStandardizeExpandsTilde() {
        let home = NSHomeDirectory()
        XCTAssertEqual(standardizePath("~/Desktop"), home + "/Desktop")
        XCTAssertEqual(standardizePath("~/Desktop/../Downloads"), home + "/Downloads")
    }
}
