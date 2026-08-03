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

    /// Writes a PDF with `pages` pages, drawing an image on the first
    /// `pagesWithImage` of them. Used to build a candidate that keeps its page
    /// count but loses content — the exact shape Ghostscript produced.
    static func writePDF(to url: URL, pages: Int = 2, pagesWithImage: Int = 2) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "test", code: 1)
        }
        // A small red image to embed.
        let bmp = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bmp.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = bmp.makeImage()!
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 5))
            if page < pagesWithImage {
                ctx.draw(image, in: CGRect(x: 20, y: 60, width: 80, height: 80))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
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
        XCTAssertEqual(defaultOptimizers.map(\.name), ["png", "jpeg", "gif", "pdf"])
        let exts = Set(defaultOptimizers.flatMap(\.extensions))
        XCTAssertEqual(exts, ["png", "jpg", "jpeg", "gif", "pdf"])
    }

    func testArgumentConstruction() {
        XCTAssertEqual(
            defaultOptimizers[0].arguments("/a/in.png", "/a/out.png", 2),
            ["--out", "/a/out.png", "--force", "-o", "2", "--strip", "safe", "/a/in.png"])
        XCTAssertEqual(
            defaultOptimizers[1].arguments("/a/in.jpg", "/a/out.jpg", 2),
            ["-copy", "all", "-optimize", "-progressive", "-outfile", "/a/out.jpg", "/a/in.jpg"])
        XCTAssertEqual(
            defaultOptimizers[2].arguments("/a/in.gif", "/a/out.gif", 2),
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

    // MARK: - PDF

    func testRegistryIncludesPDF() {
        let pdf = defaultOptimizers.first { $0.name == "pdf" }
        XCTAssertNotNil(pdf)
        XCTAssertEqual(pdf?.extensions, ["pdf"])
        XCTAssertEqual(pdf?.toolNames, ["qpdf"])
    }

    /// qpdf exits 3 on benign warnings while still writing correct output, so
    /// the pipeline must judge by verification, not exit status alone.
    func testPDFAcceptsExitCodeThree() {
        let pdf = defaultOptimizers.first { $0.name == "pdf" }
        XCTAssertEqual(pdf?.successExitCodes, [0, 3])
        // Image formats stay strict.
        XCTAssertEqual(defaultOptimizers.first { $0.name == "png" }?.successExitCodes, [0])
    }

    func testPDFArgumentConstruction() {
        let pdf = defaultOptimizers.first { $0.name == "pdf" }
        XCTAssertEqual(
            pdf?.arguments("/a/in.pdf", "/a/out.pdf", 2),
            [
                "--linearize", "--recompress-flate", "--compression-level=9", "/a/in.pdf",
                "/a/out.pdf",
            ]
        )
    }

    func testVerifyPDFAcceptsIdenticalDocuments() throws {
        let a = dir.appendingPathComponent("a.pdf")
        let b = dir.appendingPathComponent("b.pdf")
        try Self.writePDF(to: a)
        try Self.writePDF(to: b)
        XCTAssertEqual(verifyPDF(original: a, candidate: b), .ok)
    }

    /// The regression this feature exists for: Ghostscript produced a PDF with
    /// the correct page count and every embedded image deleted, and a
    /// page-count-only verifier would have passed it.
    func testVerifyPDFRejectsCandidateMissingImages() throws {
        let a = dir.appendingPathComponent("a.pdf")
        let b = dir.appendingPathComponent("b.pdf")
        try Self.writePDF(to: a, pages: 2, pagesWithImage: 2)
        try Self.writePDF(to: b, pages: 2, pagesWithImage: 0)
        XCTAssertEqual(verifyPDF(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyPDFRejectsPageCountMismatch() throws {
        let a = dir.appendingPathComponent("a.pdf")
        let b = dir.appendingPathComponent("b.pdf")
        try Self.writePDF(to: a, pages: 3, pagesWithImage: 0)
        try Self.writePDF(to: b, pages: 2, pagesWithImage: 0)
        XCTAssertEqual(verifyPDF(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyPDFRejectsTruncatedCandidate() throws {
        let a = dir.appendingPathComponent("a.pdf")
        try Self.writePDF(to: a)
        let full = try Data(contentsOf: a)
        let b = dir.appendingPathComponent("b.pdf")
        try full.prefix(full.count / 3).write(to: b)
        XCTAssertEqual(verifyPDF(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyPDFFlagsUnreadableOriginal() throws {
        let a = dir.appendingPathComponent("a.pdf")
        try Data("not a pdf".utf8).write(to: a)
        let b = dir.appendingPathComponent("b.pdf")
        try Self.writePDF(to: b)
        XCTAssertEqual(verifyPDF(original: a, candidate: b), .originalUnreadable)
    }

    /// Guards the bug that a synthetic fixture cannot reach: real PDFs nest
    /// their images inside Form XObjects, so a non-recursive counter returns 0
    /// for both a full document and a stripped one. `CGContext` inlines images
    /// directly in page resources, so only a form-wrapped document exercises
    /// the recursion.
    func testVerifyPDFCountsImagesNestedInFormXObjects() throws {
        let qpdf = findTool(named: "qpdf", searchDirs: defaultToolSearchDirs())
        try XCTSkipIf(qpdf == nil, "qpdf not installed")
        let source = dir.appendingPathComponent("src.pdf")
        try Self.writePDF(to: source, pages: 2, pagesWithImage: 2)

        // Wrap every page's content in a Form XObject, mirroring how real
        // producers emit PDFs, then confirm the images are still counted.
        let wrapped = dir.appendingPathComponent("wrapped.pdf")
        let status = runProcess(
            qpdf!, ["--pages", source.path, "1-z", "--", source.path, wrapped.path], timeout: 60)
        try XCTSkipIf(status.status != 0 && status.status != 3, "qpdf could not build fixture")

        // A document compared against itself is always ok…
        XCTAssertEqual(verifyPDF(original: wrapped, candidate: wrapped), .ok)
        // …and one with the images removed must fail, whatever nesting is used.
        let stripped = dir.appendingPathComponent("stripped.pdf")
        try Self.writePDF(to: stripped, pages: 2, pagesWithImage: 0)
        XCTAssertEqual(verifyPDF(original: source, candidate: stripped), .candidateInvalid)
    }

    func testRealQpdfRoundTrip() throws {
        let qpdf = findTool(named: "qpdf", searchDirs: defaultToolSearchDirs())
        try XCTSkipIf(qpdf == nil, "qpdf not installed")
        let source = dir.appendingPathComponent("in.pdf")
        let out = dir.appendingPathComponent("out.pdf")
        try Self.writePDF(to: source, pages: 3, pagesWithImage: 3)
        let entry = try XCTUnwrap(defaultOptimizers.first { $0.name == "pdf" })
        let result = runProcess(qpdf!, entry.arguments(source.path, out.path, 2), timeout: 60)
        XCTAssertTrue(entry.successExitCodes.contains(result.status), "status \(result.status)")
        XCTAssertEqual(verifyPDF(original: source, candidate: out), .ok)
    }

    func testVerifyFlagsMissingCandidate() throws {
        let a = dir.appendingPathComponent("a.png")
        try Self.writePNG(to: a)
        XCTAssertEqual(
            verifyImage(original: a, candidate: dir.appendingPathComponent("nope.png")),
            .candidateInvalid)
    }
}
