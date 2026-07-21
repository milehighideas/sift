import Foundation

public struct Scanner {
    let config: Config
    let now: Date
    let dryRun: Bool
    let log: (String) -> Void
    let resolver: CategoryResolver

    public init(config: Config, now: Date, dryRun: Bool, log: @escaping (String) -> Void) {
        self.config = config
        self.now = now
        self.dryRun = dryRun
        self.log = log
        self.resolver = CategoryResolver(map: config.settings.categories)
    }

    public func run() {
        let watched = Set(config.folders.map { standardized($0.path) })
        for folder in config.folders {
            guard let rule = folder.rules.first, let move = rule.actions.first?.move else { continue }
            let dest = standardized(move.to)
            let terminalDest = !watched.contains(dest)
            for file in enumerateFiles(folder) {
                process(file: file, folder: folder, rule: rule, move: move,
                        dest: dest, terminalDest: terminalDest)
            }
        }
    }

    private func process(file: URL, folder: FolderConfig, rule: Rule, move: MoveAction,
                         dest: String, terminalDest: Bool) {
        guard let added = dateAdded(of: file.path) else { return }
        let matched = (try? ruleMatches(rule, dateAdded: added, now: now)) ?? false
        if matched {
            moveFile(file, move: move, dest: dest, terminalDest: terminalDest)
        } else if terminalDest && config.settings.tagging.enabled {
            tagCountdown(file, rule: rule, added: added, dest: dest)
        }
    }

    private func moveFile(_ file: URL, move: MoveAction, dest: String, terminalDest: Bool) {
        let category = move.sortInto == "category" ? resolver.category(for: file.lastPathComponent) : ""
        let toDir = category.isEmpty
            ? URL(fileURLWithPath: dest)
            : URL(fileURLWithPath: dest).appendingPathComponent(category)
        if dryRun { log("DRY move \(file.path) -> \(toDir.path)"); return }
        do {
            guard let moved = try performMove(src: file, toDir: toDir, onConflict: move.onConflict) else {
                log("SKIP conflict \(file.path)"); return
            }
            try? setDateAdded(moved.path, to: now)
            if terminalDest && config.settings.tagging.enabled {
                let word = lastWord(dest)
                try? setSiftTag(moved.path, text: "\(config.settings.tagging.prefix) · \(word)",
                                color: 6, prefix: config.settings.tagging.prefix)
            }
            log("MOVE \(file.path) -> \(moved.path)")
        } catch {
            log("ERROR move \(file.path): \(error)")
        }
    }

    private func tagCountdown(_ file: URL, rule: Rule, added: Date, dest: String) {
        guard let value = rule.conditions.first?.value,
              let threshold = try? parseDuration(value) else { return }
        let n = remainingDays(dateAdded: added, threshold: threshold, now: now)
        guard n > 0 else { return }
        let text = "\(config.settings.tagging.prefix) · \(n)d → \(lastWord(dest))"
        if dryRun { log("DRY tag \(file.path): \(text)"); return }
        try? setSiftTag(file.path, text: text, color: 7, prefix: config.settings.tagging.prefix)
    }

    private func enumerateFiles(_ folder: FolderConfig) -> [URL] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: standardized(folder.path))
        let ignore = Set(folder.ignore ?? [])
        guard let items = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for item in items {
            if ignore.contains(item.lastPathComponent) { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if folder.recurse {
                    result.append(contentsOf: filesUnder(item))
                } else if !folder.filesOnly {
                    result.append(item)
                }
            } else {
                result.append(item)
            }
        }
        return result
    }

    private func filesUnder(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in en {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir { files.append(url) }
        }
        return files
    }

    private func standardized(_ path: String) -> String {
        (expandTilde(path) as NSString).standardizingPath
    }

    private func lastWord(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.split(separator: " ").last.map(String.init) ?? name
    }
}
