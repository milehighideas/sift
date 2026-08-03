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
        // A folder is a Review stage if it is itself the move destination of some
        // other folder (i.e. Sift populated it with category subfolders). Those
        // are the only folders we descend into one level; everything else is
        // treated as a set of whole top-level items.
        let destinations = allDestinations()
        var movedThisRun = Set<String>()
        for folder in config.folders {
            guard let rule = folder.rules.first, let move = rule.actions.first?.move else {
                continue
            }
            let dest = standardized(move.to)
            let terminalDest = !watched.contains(dest)
            let reviewStage = destinations.contains(standardized(folder.path))
            for item in enumerateItems(folder, reviewStage: reviewStage) {
                let moved = process(
                    item: item, rule: rule, move: move,
                    dest: dest, terminalDest: terminalDest,
                    skipMove: movedThisRun.contains(item.path))
                if let moved = moved { movedThisRun.insert(moved) }
            }
        }
    }

    private func allDestinations() -> Set<String> {
        var dests = Set<String>()
        for folder in config.folders {
            for rule in folder.rules {
                for action in rule.actions {
                    dests.insert(standardized(action.move.to))
                }
            }
        }
        return dests
    }

    private func process(
        item: URL, rule: Rule, move: MoveAction,
        dest: String, terminalDest: Bool, skipMove: Bool
    ) -> String? {
        // Resolved before Date Added is read: an expiring pin re-stamps the item,
        // and reading the old value first would age it on a stale clock.
        if pinned(item) { return nil }
        guard let added = dateAdded(of: item.path) else { return nil }
        let matched = (try? ruleMatches(rule, dateAdded: added, now: now)) ?? false
        if matched {
            if skipMove {
                log("SKIP double-hop guard \(item.path)")
                return nil
            }
            return moveItem(item, move: move, dest: dest, terminalDest: terminalDest)
        } else if terminalDest && config.settings.tagging.enabled {
            tagCountdown(item, rule: rule, added: added, dest: dest)
        }
        return nil
    }

    @discardableResult
    private func moveItem(_ item: URL, move: MoveAction, dest: String, terminalDest: Bool)
        -> String?
    {
        let category =
            move.sortInto == "category"
            ? resolver.category(for: item.lastPathComponent, isDirectory: isDirectory(item))
            : ""
        let toDir =
            category.isEmpty
            ? URL(fileURLWithPath: dest)
            : URL(fileURLWithPath: dest).appendingPathComponent(category)
        if dryRun {
            log("DRY move \(item.path) -> \(toDir.path)")
            return nil
        }
        do {
            guard let moved = try performMove(src: item, toDir: toDir, onConflict: move.onConflict)
            else {
                log("SKIP conflict \(item.path)")
                return nil
            }
            do { try setDateAdded(moved.path, to: now) } catch {
                log("ERROR stamp \(moved.path): \(error)")
            }
            if terminalDest && config.settings.tagging.enabled {
                let word = lastWord(dest)
                do {
                    try setSiftTag(
                        moved.path, text: "\(config.settings.tagging.prefix) · \(word)",
                        color: 6, prefix: config.settings.tagging.prefix,
                        preserving: keepPredicate)
                } catch {
                    log("ERROR tag \(moved.path): \(error)")
                }
            }
            log("MOVE \(item.path) -> \(moved.path)")
            return moved.path
        } catch {
            log("ERROR move \(item.path): \(error)")
            return nil
        }
    }

    private func tagCountdown(_ item: URL, rule: Rule, added: Date, dest: String) {
        guard let value = rule.conditions.first?.value,
            let threshold = try? parseDuration(value)
        else { return }
        let n = remainingDays(dateAdded: added, threshold: threshold, now: now)
        guard n > 0 else { return }
        let text = "\(config.settings.tagging.prefix) · \(n)d → \(lastWord(dest))"
        if dryRun {
            log("DRY tag \(item.path): \(text)")
            return
        }
        do {
            try setSiftTag(
                item.path, text: text, color: 7, prefix: config.settings.tagging.prefix,
                preserving: keepPredicate)
            log("TAG \(item.path): \(text)")
        } catch {
            log("ERROR tag \(item.path): \(error)")
        }
    }

    private var keepPredicate: (String) -> Bool {
        let prefix = config.settings.tagging.prefix
        return { isKeepTag($0, prefix: prefix) }
    }

    /// Resolves an item's keep tag and returns whether it stays put this pass.
    /// Normalizes a relative or malformed pin to an absolute one, and retires a
    /// lapsed pin by clearing the tag and re-stamping Date Added — which hands
    /// the item a full fresh countdown instead of moving it the instant its pin
    /// expires.
    private func pinned(_ item: URL) -> Bool {
        let prefix = config.settings.tagging.prefix
        let tags = rawTags(of: item.path)
        guard let tag = parseKeepTag(tags, prefix: prefix, calendar: Calendar.current) else {
            return false
        }
        switch tag {
        case .malformed(let body):
            log("WARN unparseable keep tag \"\(body)\" on \(item.path) — pinning indefinitely")
            writeKeepTag(item, text: keepTagText(prefix: prefix))
        case .relative:
            if let expiry = keepExpiry(from: tag, now: now, calendar: Calendar.current) {
                writeKeepTag(item, text: keepTagText(until: expiry, prefix: prefix))
            }
        case .until(let expiry) where now > expiry:
            return !retirePin(item)
        case .indefinite, .until:
            clearStaleCountdown(item, tags: tags)
        }
        return true
    }

    /// Clears a lapsed pin and restarts the item's clock. Returns true on
    /// success, meaning the caller should let the item age normally from now.
    private func retirePin(_ item: URL) -> Bool {
        if dryRun {
            log("DRY expire \(item.path): keep tag lapsed, resuming aging")
            return false
        }
        do {
            try setSiftTag(
                item.path, text: nil, color: 0, prefix: config.settings.tagging.prefix,
                preserving: { _ in false })
        } catch {
            log("ERROR expire \(item.path): \(error)")
            return false
        }
        do { try setDateAdded(item.path, to: now) } catch {
            log("ERROR stamp \(item.path): \(error)")
        }
        log("EXPIRE \(item.path): keep tag lapsed, resuming aging")
        return true
    }

    private func writeKeepTag(_ item: URL, text: String) {
        if dryRun {
            log("DRY normalize \(item.path): \(text)")
            return
        }
        do {
            try setSiftTag(
                item.path, text: text, color: 6, prefix: config.settings.tagging.prefix,
                preserving: { _ in false })
            log("KEEP \(item.path): \(text)")
        } catch {
            log("ERROR normalize \(item.path): \(error)")
        }
    }

    /// A pinned item must never show a countdown it will not honour. Only writes
    /// when a stale one is actually present, so a settled pin costs no syscalls.
    private func clearStaleCountdown(_ item: URL, tags: [String]) {
        let prefix = config.settings.tagging.prefix
        let stale = tags.contains { entry in
            let name = entry.components(separatedBy: "\n").first ?? entry
            return name.hasPrefix(prefix + " · ") && !isKeepTag(entry, prefix: prefix)
        }
        guard stale else { return }
        if dryRun {
            log("DRY untag \(item.path): pinned, clearing countdown")
            return
        }
        do {
            try setSiftTag(
                item.path, text: nil, color: 0, prefix: prefix, preserving: keepPredicate)
            log("UNTAG \(item.path): pinned, countdown cleared")
        } catch {
            log("ERROR untag \(item.path): \(error)")
        }
    }

    /// Collect the items to age from a folder. Items are always whole top-level
    /// entries (files, folders, or bundles) — Sift never descends into a
    /// directory it did not create. For a Review stage, category subfolders that
    /// Sift itself created are transparent: their direct children are the items
    /// to age. Everything else is returned as-is.
    private func enumerateItems(_ folder: FolderConfig, reviewStage: Bool) -> [URL] {
        let base = URL(fileURLWithPath: standardized(folder.path))
        let ignore = Set(folder.ignore ?? [])
        guard let top = listDir(base, logPath: folder.path) else { return [] }
        let categoryNames = resolver.categoryFolderNames()
        var result: [URL] = []
        for entry in top {
            if ignore.contains(entry.lastPathComponent) { continue }
            if reviewStage && isDirectory(entry) && categoryNames.contains(entry.lastPathComponent)
            {
                // Transparent: age the whole items inside Sift's own category
                // subfolder, one level down. Never descend into those items.
                if let children = listDir(entry, logPath: entry.path) {
                    result.append(contentsOf: children)
                }
            } else {
                result.append(entry)
            }
        }
        return result
    }

    private func listDir(_ url: URL, logPath: String) -> [URL]? {
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else {
            log("SKIP unreadable folder \(logPath)")
            return nil
        }
        return items
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private func standardized(_ path: String) -> String {
        (expandTilde(path) as NSString).standardizingPath
    }

    private func lastWord(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return (name.split(separator: " ").last.map(String.init) ?? name).capitalized
    }
}
