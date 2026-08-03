import Foundation

public struct ReportData {
    public let config: Config
    public let pending: [SiftEvent]
    public let history: [SiftEvent]

    public init(config: Config, pending: [SiftEvent], history: [SiftEvent]) {
        self.config = config
        self.pending = pending
        self.history = history
    }
}

/// A regenerable artifact, so it belongs in Caches — and deliberately NOT in
/// the Logs directory, which is watched and would age the report into Archive.
public func defaultReportPath() -> String {
    expandTilde("~/Library/Caches/com.brandonshutter.sift/report.html")
}

/// Pure string building: no filesystem access, so the whole page is unit
/// testable. Self-contained by construction — inline CSS, no scripts, no
/// external assets, so it opens offline forever.
public func renderReport(_ data: ReportData, generated: Date) -> String {
    let optimized = data.history.filter { $0.kind == .optimize }
    let moved = data.history.filter { $0.kind == .move }
    let saved = optimized.reduce(0) { $0 + (($1.before ?? 0) - ($1.after ?? 0)) }
    let stamp = DateFormatter.reportStamp.string(from: generated)

    var out = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Sift report</title>
        <style>\(reportCSS)</style>
        </head><body>
        <header><h1>Sift</h1><p class="sub">Generated \(esc(stamp))</p></header>
        <section class="cards">
          \(card(String(optimized.count), "files optimized"))
          \(card(formatBytes(saved), "reclaimed"))
          \(card(String(moved.count), "items moved"))
          \(card(String(data.pending.count), "items tracked"))
        </section>
        """

    out += section("Due next", pendingTable(data.pending))
    out += section("Activity", historyTable(data.history))
    out += section("Watched folders", foldersTable(data.config))
    out += section("Settings", settingsTable(data.config))
    out += "</body></html>\n"
    return out
}

// MARK: - Sections

private func pendingTable(_ pending: [SiftEvent]) -> String {
    if pending.isEmpty { return "<p class=\"empty\">Nothing tracked yet.</p>" }
    let rows =
        pending
        .sorted { ($0.remainingDays ?? 0) < ($1.remainingDays ?? 0) }
        .map { event -> String in
            let days = event.remainingDays ?? 0
            let when = days == 0 ? "<span class=\"due\">next pass</span>" : "\(days)d"
            return "<tr><td>\(when)</td><td class=\"path\">\(esc(abbreviate(event.path)))</td></tr>"
        }.joined()
    return
        "<table><thead><tr><th>Moves in</th><th>Path</th></tr></thead><tbody>\(rows)</tbody></table>"
}

private func historyTable(_ history: [SiftEvent]) -> String {
    if history.isEmpty { return "<p class=\"empty\">No activity recorded yet.</p>" }
    let rows = history.map { event -> String in
        let detail: String
        switch event.kind {
        case .optimize:
            let before = event.before ?? 0
            let after = event.after ?? 0
            let pct = before > 0 ? (before - after) * 100 / before : 0
            detail = "\(formatBytes(before)) → \(formatBytes(after)) (−\(pct)%)"
        case .move:
            detail = esc(abbreviate(event.to ?? ""))
        default:
            detail = esc(event.detail ?? "")
        }
        return """
            <tr><td class="ts">\(esc(event.ts))</td>\
            <td><span class="kind k-\(event.kind.rawValue)">\(esc(event.kind.rawValue))</span></td>\
            <td class="path">\(esc(abbreviate(event.path)))</td>\
            <td class="detail">\(detail)</td></tr>
            """
    }.joined()
    return """
        <table><thead><tr><th>When</th><th>What</th><th>Path</th><th></th></tr></thead>\
        <tbody>\(rows)</tbody></table>
        """
}

private func foldersTable(_ config: Config) -> String {
    let rows = config.folders.map { folder -> String in
        let rule = folder.rules.first
        let move = rule?.actions.first?.move
        let threshold = rule?.conditions.first?.value ?? "—"
        let ignore = (folder.ignore ?? []).joined(separator: ", ")
        return """
            <tr><td class="path">\(esc(abbreviate(folder.path)))</td>\
            <td>\(esc(rule?.name ?? "—"))</td>\
            <td>\(esc(threshold))</td>\
            <td class="path">\(esc(abbreviate(move?.to ?? "—")))</td>\
            <td>\(esc(move?.sortInto ?? "—"))</td>\
            <td>\(esc(ignore.isEmpty ? "—" : ignore))</td></tr>
            """
    }.joined()
    return """
        <table><thead><tr><th>Folder</th><th>Rule</th><th>After</th><th>Moves to</th>\
        <th>Sort</th><th>Ignores</th></tr></thead><tbody>\(rows)</tbody></table>
        """
}

private func settingsTable(_ config: Config) -> String {
    let settings = config.settings
    let optimize =
        settings.optimize.map { "enabled — skip tag “\($0.skipTag)”, level \($0.level)" }
        ?? "disabled"
    let rows = [
        ("Interval", settings.interval),
        ("Log", abbreviate(settings.log)),
        ("Tag prefix", settings.tagging.prefix),
        ("Optimize", optimize),
    ].map { "<tr><th>\(esc($0.0))</th><td>\(esc($0.1))</td></tr>" }.joined()
    return "<table class=\"kv\"><tbody>\(rows)</tbody></table>"
}

// MARK: - Helpers

private func section(_ title: String, _ body: String) -> String {
    "<section><h2>\(esc(title))</h2>\(body)</section>"
}

private func card(_ value: String, _ label: String) -> String {
    """
    <div class="card"><div class="value">\(esc(value))</div>\
    <div class="label">\(esc(label))</div></div>
    """
}

/// Filenames legitimately contain &, <, >, and quotes.
func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB"]
    var value = Double(bytes) / 1024
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: "%.1f %@", value, units[index])
}

extension DateFormatter {
    static let reportStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private let reportCSS = """
    :root { color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --muted:#6b7280; \
    --line:#e5e7eb; --card:#f9fafb; --accent:#b45309; }
    @media (prefers-color-scheme: dark) { :root { --bg:#111317; --fg:#e8e8e8; \
    --muted:#9aa0a6; --line:#2a2d33; --card:#191c21; --accent:#f59e0b; } }
    * { box-sizing:border-box; }
    body { margin:0; padding:2rem 1.5rem 4rem; background:var(--bg); color:var(--fg);
      font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif; }
    header { max-width:1100px; margin:0 auto 1.5rem; }
    h1 { margin:0; font-size:1.6rem; letter-spacing:-.02em; }
    .sub { margin:.25rem 0 0; color:var(--muted); }
    section { max-width:1100px; margin:0 auto 2rem; }
    h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.08em;
      color:var(--muted); margin:0 0 .6rem; }
    .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:.75rem; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem; }
    .card .value { font-size:1.5rem; font-weight:600; letter-spacing:-.02em; }
    .card .label { color:var(--muted); font-size:.8rem; margin-top:.15rem; }
    table { width:100%; border-collapse:collapse; font-size:13px; display:block;
      overflow-x:auto; white-space:nowrap; }
    th { text-align:left; font-weight:600; color:var(--muted); font-size:.75rem;
      text-transform:uppercase; letter-spacing:.05em; }
    th,td { padding:.45rem .7rem; border-bottom:1px solid var(--line); }
    tbody tr:last-child td { border-bottom:0; }
    .path { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }
    .ts, .detail { color:var(--muted); font-variant-numeric:tabular-nums; }
    .kind { font-size:11px; padding:.1rem .4rem; border-radius:5px; background:var(--card);
      border:1px solid var(--line); }
    .k-optimize { color:#15803d; } .k-move { color:#1d4ed8; }
    .k-pinExpire, .k-pinNormalize { color:var(--accent); }
    .due { color:var(--accent); font-weight:600; }
    .empty { color:var(--muted); font-style:italic; }
    .kv th { width:9rem; }
    """
