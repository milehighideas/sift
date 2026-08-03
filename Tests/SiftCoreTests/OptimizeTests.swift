import CoreGraphics
import ImageIO
import XCTest

@testable import SiftCore

final class OptimizeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Shared with OptimizePassTests — both are in the same test target.
    static func writePNG(to url: URL, width: Int = 16, height: Int = 16) throws {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 1)
        }
    }

    // MARK: - Settings decoding

    func testSettingsDecodeWithDefaults() throws {
        let json = Data(#"{"enabled": true}"#.utf8)
        let s = try JSONDecoder().decode(OptimizeSettings.self, from: json)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.skipTag, "Keep OG")
        XCTAssertEqual(s.level, 2)
    }

    func testSettingsDecodeExplicit() throws {
        let json = Data(#"{"enabled": false, "skipTag": "Original", "level": 4}"#.utf8)
        let s = try JSONDecoder().decode(OptimizeSettings.self, from: json)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.skipTag, "Original")
        XCTAssertEqual(s.level, 4)
    }

    // MARK: - Registry

    func testRegistryCoversExpectedFormats() {
        XCTAssertEqual(imageOptimizers.map(\.name), ["png", "jpeg", "gif"])
        let exts = Set(imageOptimizers.flatMap(\.extensions))
        XCTAssertEqual(exts, ["png", "jpg", "jpeg", "gif"])
    }

    func testArgumentConstruction() {
        XCTAssertEqual(
            imageOptimizers[0].arguments("/a/in.png", "/a/out.png", 2),
            ["--out", "/a/out.png", "--force", "-o", "2", "--strip", "safe", "/a/in.png"])
        XCTAssertEqual(
            imageOptimizers[1].arguments("/a/in.jpg", "/a/out.jpg", 2),
            ["-copy", "all", "-optimize", "-progressive", "-outfile", "/a/out.jpg", "/a/in.jpg"])
        XCTAssertEqual(
            imageOptimizers[2].arguments("/a/in.gif", "/a/out.gif", 2),
            ["-O2", "-o", "/a/out.gif", "/a/in.gif"])
    }

    // MARK: - Tool discovery

    func testFindToolPrefersEarlierDirs() throws {
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        for d in [a, b] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let tool = d.appendingPathComponent("faketool")
            try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        XCTAssertEqual(
            findTool(named: "faketool", searchDirs: [a.path, b.path]),
            a.appendingPathComponent("faketool").path)
    }

    func testFindToolSkipsNonExecutable() throws {
        let tool = dir.appendingPathComponent("notexec")
        try "x".write(to: tool, atomically: true, encoding: .utf8)
        XCTAssertNil(findTool(named: "notexec", searchDirs: [dir.path]))
    }

    func testFindToolMissingReturnsNil() {
        XCTAssertNil(findTool(named: "no-such-tool-xyz", searchDirs: [dir.path]))
    }

    func testDefaultSearchDirsSplitsPathAndAppendsImageOptim() {
        let dirs = defaultToolSearchDirs(environment: ["PATH": "/usr/bin:/opt/x/bin"])
        XCTAssertEqual(dirs, ["/usr/bin", "/opt/x/bin", imageOptimResourcesDir])
    }

    // MARK: - Image verify

    func testVerifyOkForIdenticalDimensionPNGs() throws {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try Self.writePNG(to: a)
        try Self.writePNG(to: b)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .ok)
    }

    func testVerifyRejectsTruncatedCandidate() throws {
        let a = dir.appendingPathComponent("a.png")
        try Self.writePNG(to: a)
        let full = try Data(contentsOf: a)
        let b = dir.appendingPathComponent("b.png")
        try full.prefix(full.count / 3).write(to: b)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyRejectsDimensionMismatch() throws {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try Self.writePNG(to: a, width: 16, height: 16)
        try Self.writePNG(to: b, width: 8, height: 8)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyFlagsUnreadableOriginal() throws {
        let a = dir.appendingPathComponent("a.png")
        try Data("not an image".utf8).write(to: a)
        let b = dir.appendingPathComponent("b.png")
        try Self.writePNG(to: b)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .originalUnreadable)
    }

    func testVerifyFlagsMissingCandidate() throws {
        let a = dir.appendingPathComponent("a.png")
        try Self.writePNG(to: a)
        XCTAssertEqual(
            verifyImage(original: a, candidate: dir.appendingPathComponent("nope.png")),
            .candidateInvalid)
    }
}
