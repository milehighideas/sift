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

    public init(
        name: String, extensions: Set<String>, toolNames: [String],
        arguments: @escaping (String, String, Int) -> [String],
        verify: @escaping (URL, URL) -> VerifyResult
    ) {
        self.name = name
        self.extensions = extensions
        self.toolNames = toolNames
        self.arguments = arguments
        self.verify = verify
    }
}

/// oxipng suppresses output that is not smaller unless forced. Sift's own size
/// comparison is the single arbiter for every format, so always take the tool's
/// output and judge it here.
public let imageOptimizers: [FileOptimizer] = [
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
]

public let imageOptimResourcesDir =
    "/Applications/ImageOptim.app/Contents/Frameworks/ImageOptimGPL.framework/Versions/A/Resources"

/// $PATH first, then the CLI binaries ImageOptim.app ships in its bundle. The
/// GUI app is never launched — only its optimizers are borrowed, so the feature
/// keeps working whether the user has Homebrew tools, the app, or both.
public func defaultToolSearchDirs(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return pathDirs + [imageOptimResourcesDir]
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

private func decodeComplete(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceGetStatus(source) == .statusComplete
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
