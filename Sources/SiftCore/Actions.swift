import Foundation

/// Returns `dst` if free, else appends " 2", " 3", … before the extension.
public func uniqueDestination(_ dst: URL) -> URL {
    let fm = FileManager.default
    if !fm.fileExists(atPath: dst.path) { return dst }
    let dir = dst.deletingLastPathComponent()
    let ext = dst.pathExtension
    let base = dst.deletingPathExtension().lastPathComponent
    var i = 2
    while true {
        let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
        let candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        i += 1
    }
}

/// Moves `src` into `toDir` (created on demand). `FileManager.moveItem`
/// transparently handles cross-volume moves via copy+remove.
/// Returns the final URL, or nil if skipped on conflict.
public func performMove(src: URL, toDir: URL, onConflict: String) throws -> URL? {
    let fm = FileManager.default
    try fm.createDirectory(at: toDir, withIntermediateDirectories: true)
    var dst = toDir.appendingPathComponent(src.lastPathComponent)
    if fm.fileExists(atPath: dst.path) {
        switch onConflict {
        case "skip": return nil
        case "replace": try fm.removeItem(at: dst)
        default: dst = uniqueDestination(dst)
        }
    }
    try fm.moveItem(at: src, to: dst)
    return dst
}
