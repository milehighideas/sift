import XCTest
@testable import SiftCore

final class LaunchdTests: XCTestCase {
    func testPlistContents() throws {
        let plist = makeLaunchdPlist(
            binaryPath: "/usr/local/bin/sift",
            configPath: "/Users/x/.config/sift/sift.json",
            interval: 3600,
            logPath: "/Users/x/Library/Logs/sift.log")
        XCTAssertTrue(plist.contains("<string>com.brandonshutter.sift</string>"))
        XCTAssertTrue(plist.contains("<integer>3600</integer>"))
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/sift</string>"))
        XCTAssertTrue(plist.contains("<string>run</string>"))
        // Parses as a valid plist.
        let data = Data(plist.utf8)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        XCTAssertNotNil(obj as? [String: Any])
    }
}
