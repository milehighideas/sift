import Foundation

/// Resolves an item's category from its extension using a category→extensions
/// map. Extensions are expected to be unique across categories; keys are sorted
/// for deterministic resolution. Files with no recognized extension map to
/// "Other"; directories (plain folders, or bundles whose extension isn't in the
/// map) map to "Folders". Recognized bundle extensions (e.g. rtfd → documents,
/// app → installers) categorize by extension like any other item.
public struct CategoryResolver {
    public let map: [String: [String]]
    public let fileFallback = "Other"
    public let folderFallback = "Folders"

    public init(map: [String: [String]]) {
        self.map = map
    }

    public func category(for filename: String, isDirectory: Bool = false) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            for (name, exts) in map.sorted(by: { $0.key < $1.key }) {
                if exts.contains(where: { $0.lowercased() == ext }) {
                    return name.capitalized
                }
            }
        }
        return isDirectory ? folderFallback : fileFallback
    }

    /// The set of category subfolder names Sift itself creates — the capitalized
    /// map keys plus the "Folders" and "Other" fallbacks. Used to transparently
    /// descend one level into Sift's own category folders when aging a Review
    /// stage, without descending into user folders or bundles.
    public func categoryFolderNames() -> Set<String> {
        var names = Set(map.keys.map { $0.capitalized })
        names.insert(folderFallback)
        names.insert(fileFallback)
        return names
    }
}
