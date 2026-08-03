import Darwin
import Foundation

/// The optimize pass: walks every watched folder plus every move destination
/// and pushes each candidate file through a uniform temp-file pipeline. Runs
/// before the aging pass and restores Date Added afterward, so aging is blind
/// to whether a file was just optimized.
///
/// Every format goes through the same path — no tool is trusted to write in
/// place, because in-place semantics differ per tool and getting one wrong
/// destroys the file's aging clock and Finder tags. The original is replaced
/// only by a verified, strictly smaller candidate.
public struct OptimizePass {
    let config: Config
    let dryRun: Bool
    let log: (String) -> Void
    let settings: OptimizeSettings
    let resolver: CategoryResolver
    let optimizers: [FileOptimizer]
    let toolPaths: [String: String]
    let timeout: TimeInterval

    public init(
        config: Config, dryRun: Bool, log: @escaping (String) -> Void,
        optimizers: [FileOptimizer] = imageOptimizers,
        toolPaths: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) {
        self.config = config
        self.dryRun = dryRun
        self.log = log
        self.settings = config.settings.optimize ?? OptimizeSettings(enabled: false)
        self.resolver = CategoryResolver(map: config.settings.categories)
        self.optimizers = optimizers
        self.toolPaths = toolPaths ?? Self.resolveTools(optimizers)
        self.timeout = timeout
    }

    static func resolveTools(_ optimizers: [FileOptimizer]) -> [String: String] {
        let dirs = defaultToolSearchDirs()
        var resolved: [String: String] = [:]
        for optimizer in optimizers {
            for tool in optimizer.toolNames {
                if let path = findTool(named: tool, searchDirs: dirs) {
                    resolved[optimizer.name] = path
                    break
                }
            }
        }
        return resolved
    }

    public func run() {
        guard settings.enabled else { return }
        for optimizer in optimizers where toolPaths[optimizer.name] == nil {
            log("SKIP no optimizer for \(optimizer.name)")
        }
        for file in candidates() { process(file) }
    }

    // MARK: - Walk

    /// Watched folders plus their move destinations, deduplicated. Destination
    /// folders get the one-level descent into Sift's own category subfolders;
    /// user folders and bundles stay opaque, matching the aging pass.
    private func candidates() -> [URL] {
        let destinations = Set(
            config.folders.flatMap { folder in
                folder.rules.flatMap { rule in
                    rule.actions.map { standardizePath($0.move.to) }
                }
            })
        var folders: [(url: URL, ignore: Set<String>, descend: Bool)] = []
        var seen = Set<String>()
        for folder in config.folders {
            let path = standardizePath(folder.path)
            guard seen.insert(path).inserted else { continue }
            folders.append(
                (URL(fileURLWithPath: path), Set(folder.ignore ?? []), destinations.contains(path)))
        }
        for destination in destinations.sorted() where seen.insert(destination).inserted {
            folders.append((URL(fileURLWithPath: destination), [], true))
        }

        let categoryNames = resolver.categoryFolderNames()
        var result: [URL] = []
        for folder in folders {
            guard let top = listDir(folder.url) else { continue }
            for entry in top {
                if folder.ignore.contains(entry.lastPathComponent) { continue }
                if isDirectory(entry) {
                    guard folder.descend, categoryNames.contains(entry.lastPathComponent),
                        let children = listDir(entry)
                    else { continue }
                    result.append(contentsOf: children.filter(isCandidate))
                } else if isCandidate(entry) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    private func listDir(_ url: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    }

    private func isCandidate(_ url: URL) -> Bool {
        !isDirectory(url) && optimizer(for: url) != nil
    }

    /// A partial download ("photo.png.crdownload") has extension "crdownload"
    /// and matches no registry entry, so the extension filter is also the
    /// in-progress guard.
    private func optimizer(for url: URL) -> FileOptimizer? {
        let ext = url.pathExtension.lowercased()
        return optimizers.first { $0.extensions.contains(ext) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: - Pipeline

    private func process(_ file: URL) {
        let prefix = config.settings.tagging.prefix
        let tags = rawTags(of: file.path)
        if tags.contains(where: { isOptimizedTag($0, prefix: prefix) }) { return }
        if tags.contains(where: { isKeepOGTag($0, prefix: prefix, skipTag: settings.skipTag) }) {
            log("SKIP \(settings.skipTag) \(file.path)")
            return
        }
        guard let optimizer = optimizer(for: file), let tool = toolPaths[optimizer.name] else {
            return
        }
        if dryRun {
            log("DRY optimize \(file.path)")
            return
        }

        let originalSize = size(of: file)
        let added = dateAdded(of: file.path)
        let attrs = captureXattrs(of: file.path)
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".sift-opt-\(UUID().uuidString).\(file.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = runProcess(
            tool, optimizer.arguments(file.path, temp.path, settings.level), timeout: timeout)
        if result.timedOut {
            log("ERROR optimize timeout \(file.path)")
            return
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: temp.path) else {
            log("ERROR optimize \(file.path): tool exited \(result.status)")
            return
        }

        switch optimizer.verify(file, temp) {
        case .originalUnreadable:
            // Most likely a file still being written. Leave it unmarked so it
            // is optimized properly once complete.
            return
        case .candidateInvalid:
            log("ERROR verify \(file.path)")
            return
        case .ok:
            break
        }

        let newSize = size(of: temp)
        guard newSize > 0, newSize < originalSize else {
            // Already as small as this tool can make it — done, not retryable.
            mark(file, prefix: prefix)
            return
        }
        guard rename(temp.path, file.path) == 0 else {
            log("ERROR replace \(file.path): errno \(errno)")
            return
        }
        if let added = added {
            do { try setDateAdded(file.path, to: added) } catch {
                log("ERROR stamp \(file.path): \(error)")
            }
        }
        if !restoreXattrs(attrs, to: file.path) { log("ERROR xattrs \(file.path)") }
        mark(file, prefix: prefix)
        let saved = (originalSize - newSize) * 100 / max(originalSize, 1)
        log("OPT \(file.path): \(originalSize) -> \(newSize) bytes (\(saved)%)")
    }

    private func mark(_ file: URL, prefix: String) {
        do { try addSiftTag(file.path, text: "\(prefix) · Optimized", color: 2) } catch {
            log("ERROR mark \(file.path): \(error)")
        }
    }

    private func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
