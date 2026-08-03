import CoreGraphics
import Foundation
import ImageIO

/// Settings for the optimize pass. Optional in config: an absent block means
/// the feature is off; absent fields take defaults.
public struct OptimizeSettings: Codable {
    public let enabled: Bool
    public let skipTag: String
    public let level: Int

    public init(enabled: Bool, skipTag: String = "Keep OG", level: Int = 2) {
        self.enabled = enabled
        self.skipTag = skipTag
        self.level = level
    }

    private enum CodingKeys: String, CodingKey { case enabled, skipTag, level }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        skipTag = try container.decodeIfPresent(String.self, forKey: .skipTag) ?? "Keep OG"
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 2
    }
}

public enum VerifyResult: Equatable {
    case ok
    case originalUnreadable
    case candidateInvalid
}

/// One format's optimizer: the extensions it owns, the external tool that runs
/// it, how to build that tool's arguments, and how to verify a candidate
/// against the original. Everything else in the pipeline is format-neutral, so
/// adding a new type (PDF) is one more value in the registry and nothing else.
public struct FileOptimizer {
    public let name: String
    public let extensions: Set<String>
    public let toolNames: [String]
    public let arguments: (String, String, Int) -> [String]
    public let verify: (URL, URL) -> VerifyResult
    /// Exit statuses that mean "output was produced". Most tools use 0 alone,
    /// but qpdf exits 3 on benign warnings while still writing correct output,
    /// so the arbiter has to be verification rather than exit status.
    public let successExitCodes: Set<Int32>

    public init(
        name: String, extensions: Set<String>, toolNames: [String],
        arguments: @escaping (String, String, Int) -> [String],
        verify: @escaping (URL, URL) -> VerifyResult,
        successExitCodes: Set<Int32> = [0]
    ) {
        self.name = name
        self.extensions = extensions
        self.toolNames = toolNames
        self.arguments = arguments
        self.verify = verify
        self.successExitCodes = successExitCodes
    }
}

/// oxipng suppresses output that is not smaller unless forced. Sift's own size
/// comparison is the single arbiter for every format, so always take the tool's
/// output and judge it here.
public let defaultOptimizers: [FileOptimizer] = [
    FileOptimizer(
        name: "png", extensions: ["png"], toolNames: ["oxipng"],
        arguments: { input, output, level in
            ["--out", output, "--force", "-o", String(level), "--strip", "safe", input]
        },
        verify: { verifyImage(original: $0, candidate: $1) }),
    FileOptimizer(
        name: "jpeg", extensions: ["jpg", "jpeg"], toolNames: ["jpegtran"],
        arguments: { input, output, _ in
            ["-copy", "all", "-optimize", "-progressive", "-outfile", output, input]
        },
        verify: { verifyImage(original: $0, candidate: $1) }),
    FileOptimizer(
        name: "gif", extensions: ["gif"], toolNames: ["gifsicle"],
        arguments: { input, output, _ in ["-O2", "-o", output, input] },
        verify: { verifyImage(original: $0, candidate: $1) }),
    FileOptimizer(
        name: "pdf", extensions: ["pdf"], toolNames: ["qpdf"],
        arguments: { input, output, _ in
            ["--linearize", "--recompress-flate", "--compression-level=9", input, output]
        },
        verify: { verifyPDF(original: $0, candidate: $1) },
        successExitCodes: [0, 3]),
]

public let imageOptimResourcesDir =
    "/Applications/ImageOptim.app/Contents/Frameworks/ImageOptimGPL.framework/Versions/A/Resources"

/// Homebrew prefixes, searched explicitly because launchd does not inherit the
/// user's shell PATH — the agent runs with `/usr/bin:/bin:/usr/sbin:/sbin`.
/// Without these, any tool installed only via Homebrew is invisible to the
/// deployed agent while remaining perfectly discoverable from a terminal, so
/// the failure never shows up in testing.
public let homebrewToolDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

/// $PATH first (an explicit user setting wins), then Homebrew, then the CLI
/// binaries ImageOptim.app ships in its bundle. The GUI app is never launched —
/// only its optimizers are borrowed, so the feature keeps working whether the
/// user has Homebrew tools, the app, or both.
public func defaultToolSearchDirs(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return pathDirs + homebrewToolDirs + [imageOptimResourcesDir]
}

public func findTool(named name: String, searchDirs: [String]) -> String? {
    for dir in searchDirs {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Both files must decode completely and agree on pixel dimensions.
/// `statusComplete` is the load-bearing part: ImageIO happily returns a partial
/// image for a truncated file, which is exactly the half-written-download case.
public func verifyImage(original: URL, candidate: URL) -> VerifyResult {
    guard let source = decodeComplete(original) else { return .originalUnreadable }
    guard let result = decodeComplete(candidate),
        result.width == source.width, result.height == source.height
    else { return .candidateInvalid }
    return .ok
}

/// Page count alone is not enough. Ghostscript, measured on a real 203-page
/// document, produced a PDF with every one of its 169 embedded images deleted
/// and all 203 pages intact — a 96% "saving" that a page-count check would have
/// waved through, overwriting the original. Comparing embedded-image counts is
/// what makes a content-destroying tool fail closed.
public func verifyPDF(original: URL, candidate: URL) -> VerifyResult {
    guard let source = CGPDFDocument(original as CFURL), source.numberOfPages > 0 else {
        return .originalUnreadable
    }
    guard let result = CGPDFDocument(candidate as CFURL),
        result.numberOfPages == source.numberOfPages,
        imageCount(result) == imageCount(source)
    else { return .candidateInvalid }
    return .ok
}

/// Counts image XObjects across every page, **descending into Form XObjects**.
///
/// The recursion is not optional. Real-world PDFs (this was measured on a
/// 203-page manual) put zero images directly in page resources and wrap all of
/// them in 252 Form XObjects; a non-recursive count returns 0 for both the
/// original and a stripped candidate, making the safety check silently vacuous.
/// PDFs generated by `CGContext` do inline their images, so a synthetic fixture
/// will not expose this — it has to be tested against a real document.
///
/// A shared XObject referenced from several places counts once per reference:
/// this compares two documents walked identically, so consistency matters more
/// than absolute accuracy.
private func imageCount(_ document: CGPDFDocument) -> Int {
    var total = 0
    for index in 1...max(document.numberOfPages, 1) {
        guard let page = document.page(at: index), let dict = page.dictionary else { continue }
        countImages(inResourcesOf: dict, depth: 0, into: &total)
    }
    return total
}

/// Depth is capped because Form XObjects may reference one another cyclically.
private func countImages(inResourcesOf dict: CGPDFDictionaryRef, depth: Int, into total: inout Int)
{
    guard depth < 8 else { return }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources = resources
    else { return }
    var xobjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects = xobjects
    else { return }

    // Collect first, recurse after: CGPDFDictionaryApplyFunction takes a C
    // function pointer, which cannot capture `total` or recurse with context.
    var forms: [CGPDFDictionaryRef] = []
    var found = (images: 0, forms: [CGPDFDictionaryRef]())
    CGPDFDictionaryApplyFunction(
        xobjects,
        { _, value, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream = stream,
                let streamDict = CGPDFStreamGetDictionary(stream)
            else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype = subtype
            else { return }
            let found = info!.assumingMemoryBound(
                to: (images: Int, forms: [CGPDFDictionaryRef]).self)
            switch String(cString: subtype) {
            case "Image": found.pointee.images += 1
            case "Form": found.pointee.forms.append(streamDict)
            default: break
            }
        }, &found)

    total += found.images
    forms = found.forms
    for form in forms { countImages(inResourcesOf: form, depth: depth + 1, into: &total) }
}

private func decodeComplete(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceGetStatus(source) == .statusComplete
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
