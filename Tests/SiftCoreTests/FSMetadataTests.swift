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
        try setSiftTag(
            path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift", preserving: { _ in false })
        try setSiftTag(
            path, text: "Sift · Delete", color: 6, prefix: "Sift", preserving: { _ in false })
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Delete") })
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · 3d") })
    }

    func testSiftTagNilClears() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try setSiftTag(
            path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift", preserving: { _ in false })
        try setSiftTag(path, text: nil, color: 0, prefix: "Sift", preserving: { _ in false })
        XCTAssertFalse(rawTags(of: path).contains { $0.hasPrefix("Sift · ") })
    }

    func testSiftTagPreservesKeepTagWhileReplacingOwn() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let keepPredicate = { isKeepTag($0, prefix: "Sift") }
        try setSiftTag(
            path, text: "Sift · Keep until 2026-09-02", color: 6, prefix: "Sift",
            preserving: keepPredicate)
        try setSiftTag(
            path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift", preserving: keepPredicate)
        let tags = rawTags(of: path)
        // The pin survives a countdown rewrite; the countdown still lands.
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Keep until 2026-09-02") })
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · 3d → Delete") })
    }

    func testXattrCaptureRestoreRoundTrip() throws {
        let src = try tempFile()
        let dst = try tempFile()
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        try setSiftTag(
            src, text: "Sift · 3d → Delete", color: 7, prefix: "Sift",
            preserving: { _ in false })
        let attrs = captureXattrs(of: src)
        XCTAssertFalse(attrs.isEmpty)
        XCTAssertTrue(restoreXattrs(attrs, to: dst))
        XCTAssertEqual(rawTags(of: dst), rawTags(of: src))
    }

    /// macOS attaches its own attributes (com.apple.provenance) to every new
    /// file, so "no xattrs" is not a reachable state. What matters is that an
    /// untagged file carries no user-tags attribute, and that whatever the
    /// system did attach round-trips rather than erroring on restore.
    func testCaptureXattrsOnUntaggedFileHasNoUserTags() throws {
        let src = try tempFile()
        let dst = try tempFile()
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        let attrs = captureXattrs(of: src)
        XCTAssertFalse(attrs.contains { $0.name.hasSuffix("_kMDItemUserTags") })
        XCTAssertTrue(restoreXattrs(attrs, to: dst))
        XCTAssertTrue(rawTags(of: dst).isEmpty)
    }

    func testAddSiftTagAppendsWithoutTouchingOthers() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try setSiftTag(
            path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift",
            preserving: { _ in false })
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains("Sift · Optimized\n2"))
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · 3d → Delete") })
    }

    func testAddSiftTagIsIdempotent() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        let markers = rawTags(of: path).filter { $0.hasPrefix("Sift · Optimized") }
        XCTAssertEqual(markers.count, 1)
    }

    func testSiftTagClearReplacesKeepTagWhenNotPreserved() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try setSiftTag(
            path, text: "Sift · Keep 30d", color: 6, prefix: "Sift", preserving: { _ in false })
        // Normalizing a pin rewrites it, so the keep tag must NOT be preserved there.
        try setSiftTag(
            path, text: "Sift · Keep until 2026-09-02", color: 6, prefix: "Sift",
            preserving: { _ in false })
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Keep until 2026-09-02") })
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · Keep 30d") })
    }
}
