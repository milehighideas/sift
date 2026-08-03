import XCTest

@testable import SiftCore

final class LaunchdTests: XCTestCase {
    func testPlistContents() throws {
        let plist = makeLaunchdPlist(
            binaryPath: "/usr/local/bin/sift",
            configPath: "/Users/x/.config/sift/sift.json",
            interval: 3600,
            logPath: "/Users/x/Library/Logs/sift.log",
            watchPaths: [])
        XCTAssertTrue(plist.contains("<string>com.brandonshutter.sift</string>"))
        XCTAssertTrue(plist.contains("<integer>3600</integer>"))
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/sift</string>"))
        XCTAssertTrue(plist.contains("<string>run</string>"))
        XCTAssertTrue(plist.contains("<key>ThrottleInterval</key>"))
        XCTAssertFalse(plist.contains("<key>WatchPaths</key>"))
        // Parses as a valid plist.
        let data = Data(plist.utf8)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        XCTAssertNotNil(obj as? [String: Any])
    }

    func testPlistIncludesWatchPaths() throws {
        let plist = makeLaunchdPlist(
            binaryPath: "/usr/local/bin/sift",
            configPath: "/Users/x/.config/sift/sift.json",
            interval: 3600,
            logPath: "/Users/x/Library/Logs/sift.log",
            watchPaths: ["/Users/x/Desktop", "/Users/x/Downloads"])
        XCTAssertTrue(plist.contains("<key>WatchPaths</key>"))
        XCTAssertTrue(plist.contains("<string>/Users/x/Desktop</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/x/Downloads</string>"))
        // StartInterval survives: aging must still tick when nothing changes.
        XCTAssertTrue(plist.contains("<key>StartInterval</key>"))
    }

    private func watchConfig(log: String, folders: [FolderConfig]) -> Config {
        let settings = Settings(
            interval: "1h", log: log, dryRun: false, categories: [:],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        return Config(settings: settings, folders: folders)
    }

    private func folder(_ path: String, to destination: String) -> FolderConfig {
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        return FolderConfig(
            path: path, ignore: nil,
            rules: [
                Rule(
                    name: "r-\(path)", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: destination, sortInto: "none", onConflict: "rename"))
                    ])
            ])
    }

    func testWatchPathsExcludesLogDirectory() {
        // The log folder is a watched live folder (the rotation rule), but
        // watching it would loop: log write -> launchd wake -> run -> log write.
        let config = watchConfig(
            log: "/Users/x/Library/Logs/Sift/sift.log",
            folders: [
                folder("/Users/x/Desktop", to: "/Users/x/Desktop/Desktop to Review"),
                folder("/Users/x/Library/Logs/Sift", to: "/Users/x/Library/Logs/Sift/Archive"),
            ])
        XCTAssertEqual(watchPaths(for: config), ["/Users/x/Desktop"])
    }

    func testWatchPathsExcludesLogDirectoryWithTilde() {
        // settings.log usually carries a tilde; comparison must expand it.
        let home = NSHomeDirectory()
        let config = watchConfig(
            log: "~/Library/Logs/Sift/sift.log",
            folders: [
                folder("\(home)/Desktop", to: "\(home)/Desktop/Desktop to Review"),
                folder("~/Library/Logs/Sift", to: "~/Library/Logs/Sift/Archive"),
            ])
        XCTAssertEqual(watchPaths(for: config), ["\(home)/Desktop"])
    }

    func testWatchPathsUnaffectedWhenLogLivesElsewhere() {
        let config = watchConfig(
            log: "/tmp/sift.log",
            folders: [folder("/Users/x/Desktop", to: "/Users/x/Desktop/Desktop to Review")])
        XCTAssertEqual(watchPaths(for: config), ["/Users/x/Desktop"])
    }

    func testWatchPathsAreLiveFoldersOnly() {
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let live = FolderConfig(
            path: "/Users/x/Desktop", ignore: nil,
            rules: [
                Rule(
                    name: "r", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: "/Users/x/Desktop/Desktop to Review",
                                sortInto: "category", onConflict: "rename"))
                    ])
            ])
        let review = FolderConfig(
            path: "/Users/x/Desktop/Desktop to Review", ignore: nil,
            rules: [
                Rule(
                    name: "r2", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: "/Users/x/Desktop/Desktop to Delete",
                                sortInto: "category", onConflict: "rename"))
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: "/tmp/l", dryRun: false, categories: [:],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        let config = Config(settings: settings, folders: [live, review])
        // Review is a move destination, so Sift's own writes there must not
        // wake launchd; only the live folder is watched.
        XCTAssertEqual(watchPaths(for: config), ["/Users/x/Desktop"])
    }
}
