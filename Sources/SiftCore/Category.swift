import Foundation

/// Resolves a file's category from its extension using a category→extensions map.
/// Extensions are expected to be unique across categories; keys are sorted for
/// deterministic resolution. Unmatched or extensionless files map to "Other".
public struct CategoryResolver {
    public let map: [String: [String]]
    public let fallback = "Other"

    public init(map: [String: [String]]) {
        self.map = map
    }

    public func category(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext.isEmpty { return fallback }
        for (name, exts) in map.sorted(by: { $0.key < $1.key }) {
            if exts.contains(where: { $0.lowercased() == ext }) {
                return name.capitalized
            }
        }
        return fallback
    }
}
