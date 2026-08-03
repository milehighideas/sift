import XCTest

@testable import SiftCore

final class ShellTests: XCTestCase {
    func testCapturesExitStatus() {
        let r = runProcess("/bin/sh", ["-c", "exit 3"], timeout: 10)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.timedOut)
    }

    func testZeroExit() {
        let r = runProcess("/bin/sh", ["-c", "true"], timeout: 10)
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.timedOut)
    }

    func testTimeoutKillsProcess() {
        let start = Date()
        let r = runProcess("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        // Came back promptly, not after 30s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingBinaryReportsFailure() {
        let r = runProcess("/no/such/tool", [], timeout: 5)
        XCTAssertEqual(r.status, -1)
        XCTAssertFalse(r.timedOut)
    }
}
