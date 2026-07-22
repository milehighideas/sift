import XCTest

@testable import SiftCore

final class FSMetadataTests: XCTestCase {
    private func tempFile() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-meta-\(UUID().uuidString).txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testDateAddedRoundTrip() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let target = Date(timeIntervalSince1970: 1_500_000_000)
        try setDateAdded(path, to: target)
        let read = try XCTUnwrap(dateAdded(of: path))
        XCTAssertEqual(read.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 2)
    }

    func testSiftTagReplacesOwnAndPreservesOthers() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try setSiftTag(path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift")
        try setSiftTag(path, text: "Sift · Delete", color: 6, prefix: "Sift")
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Delete") })
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · 3d") })
    }

    func testSiftTagNilClears() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try setSiftTag(path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift")
        try setSiftTag(path, text: nil, color: 0, prefix: "Sift")
        XCTAssertFalse(rawTags(of: path).contains { $0.hasPrefix("Sift · ") })
    }
}
