import Foundation

/// A machine-readable record of something Sift actually did. The text log is
/// for humans; this is the data source for `sift report`. Countdown-tag
/// rewrites are deliberately absent — they are per-pass churn (6,216 of 11,473
/// lines in the production log) and would drown real activity.
public enum EventKind: String, Codable {
    case move
    case optimize
    case pinNormalize
    case pinExpire
    /// Dry-run only: what *would* happen. Never written to disk.
    case pending
}

public struct SiftEvent: Codable, Equatable {
    public let ts: String
    public let kind: EventKind
    public let path: String
    public let to: String?
    public let before: Int?
    public let after: Int?
    public let remainingDays: Int?
    public let detail: String?

    public init(
        ts: String, kind: EventKind, path: String, to: String? = nil,
        before: Int? = nil, after: Int? = nil, remainingDays: Int? = nil,
        detail: String? = nil
    ) {
        self.ts = ts
        self.kind = kind
        self.path = path
        self.to = to
        self.before = before
        self.after = after
        self.remainingDays = remainingDays
        self.detail = detail
    }

    public static func make(
        kind: EventKind, path: String, to: String? = nil,
        before: Int? = nil, after: Int? = nil, remainingDays: Int? = nil,
        detail: String? = nil
    ) -> SiftEvent {
        SiftEvent(
            ts: eventStampFormatter.string(from: Date()), kind: kind, path: path,
            to: to, before: before, after: after, remainingDays: remainingDays,
            detail: detail)
    }
}

/// Fractional seconds are load-bearing, not decoration: a single pass performs
/// many actions per second, and second-granular stamps make the history sort
/// arbitrarily within each second — moves appearing above the optimize that
/// preceded them. The format is fixed-width, so lexical sorting stays correct.
private let eventStampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Appends one JSON object per line. Failures are swallowed: a missing history
/// row must never break a run.
public struct EventLog {
    public let path: String

    public init(path: String) {
        self.path = expandTilde(path)
    }

    public func append(_ event: SiftEvent) {
        guard let data = try? JSONEncoder().encode(event),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((json + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// Beside the text log, so it rotates through the same aging rule.
public func eventLogPath(for config: Config) -> String {
    let logDir = (standardizePath(config.settings.log) as NSString).deletingLastPathComponent
    return (logDir as NSString).appendingPathComponent("events.jsonl")
}

/// Malformed lines are skipped rather than failing the whole read — the file is
/// appended to by a background agent that can be killed mid-write.
public func readEvents(at path: String) -> [SiftEvent] {
    guard let text = try? String(contentsOfFile: expandTilde(path), encoding: .utf8) else {
        return []
    }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
        try? decoder.decode(SiftEvent.self, from: Data(line.utf8))
    }
}

/// The live event log plus every archived one, newest first.
public func readAllEvents(logDirectory: String) -> [SiftEvent] {
    let dir = standardizePath(logDirectory) as NSString
    var events = readEvents(at: dir.appendingPathComponent("events.jsonl"))
    let archive = dir.appendingPathComponent("Archive")
    let archived =
        (try? FileManager.default.contentsOfDirectory(atPath: archive))?
        .filter { $0.hasPrefix("events") && $0.hasSuffix(".jsonl") }
        .sorted() ?? []
    for name in archived {
        events += readEvents(at: (archive as NSString).appendingPathComponent(name))
    }
    return events.sorted { $0.ts > $1.ts }
}
