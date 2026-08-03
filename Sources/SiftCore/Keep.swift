import Foundation

/// A parsed `<prefix> · Keep …` Finder tag. Any form of this tag pins its item:
/// Sift will not move it out of a live folder or advance it from Review to
/// Delete. `malformed` still pins — a typo must never cause a file the user
/// tried to protect to be moved.
public enum KeepTag: Equatable {
    case indefinite
    case relative(TimeInterval)
    case until(Date)
    case malformed(String)
}

private let keepToken = "Keep"
private let untilToken = "until"

private let isoFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

/// True when a raw tag entry is Sift's keep tag, in any of its forms. Callers
/// pass this to `setSiftTag(preserving:)` so rewriting a countdown tag does not
/// strip the pin.
public func isKeepTag(_ entry: String, prefix: String) -> Bool {
    keepBody(entry, prefix: prefix) != nil
}

/// Parses the first keep tag out of a raw user-tags list. Returns nil when the
/// item carries no keep tag, which is the overwhelmingly common case.
public func parseKeepTag(_ entries: [String], prefix: String, calendar: Calendar) -> KeepTag? {
    for entry in entries {
        if let body = keepBody(entry, prefix: prefix) {
            return parseKeepBody(body, calendar: calendar)
        }
    }
    return nil
}

/// The instant a pin lapses, or nil when it never does. Relative durations round
/// up to the end of the day they land in, so a pin is never cut short.
public func keepExpiry(from tag: KeepTag, now: Date, calendar: Calendar) -> Date? {
    switch tag {
    case .relative(let interval):
        return endOfDay(now.addingTimeInterval(interval), calendar: calendar)
    case .until(let date):
        return date
    case .indefinite, .malformed:
        return nil
    }
}

/// Renders an absolute expiry back to tag text.
public func keepTagText(until date: Date, prefix: String) -> String {
    "\(prefix) · \(keepToken) \(untilToken) \(isoFormatter.string(from: date))"
}

/// Tag text for a pin with no expiry.
public func keepTagText(prefix: String) -> String {
    "\(prefix) · \(keepToken)"
}

/// The portion of a tag entry following `<prefix> · Keep`, or nil when the entry
/// is not Sift's keep tag. Recognition requires the first whitespace-delimited
/// token to equal `Keep` exactly, so a user's own `Sift · Keepsakes` tag is left
/// entirely alone.
private func keepBody(_ entry: String, prefix: String) -> String? {
    let name = entry.components(separatedBy: "\n").first ?? entry
    let ownPrefix = prefix + " · "
    guard name.hasPrefix(ownPrefix) else { return nil }
    var fields = name.dropFirst(ownPrefix.count).split(separator: " ").map(String.init)
    guard fields.first == keepToken else { return nil }
    fields.removeFirst()
    return fields.joined(separator: " ")
}

private func parseKeepBody(_ body: String, calendar: Calendar) -> KeepTag {
    if body.isEmpty { return .indefinite }
    let fields = body.split(separator: " ").map(String.init)
    if fields.first == untilToken {
        guard fields.count == 2, let date = parseIsoDate(fields[1], calendar: calendar) else {
            return .malformed(body)
        }
        return .until(date)
    }
    guard fields.count == 1, let interval = try? parseDuration(body) else {
        return .malformed(body)
    }
    return .relative(interval)
}

/// Strict `YYYY-MM-DD`, resolved to the end of that day so the named date is
/// inclusive. Components are round-tripped because `Calendar.date(from:)`
/// silently rolls impossible values over (month 13 becomes January of the next
/// year), which would turn a typo into a valid far-future pin.
private func parseIsoDate(_ text: String, calendar: Calendar) -> Date? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
        let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    guard let start = calendar.date(from: comps),
        calendar.component(.year, from: start) == year,
        calendar.component(.month, from: start) == month,
        calendar.component(.day, from: start) == day
    else { return nil }
    return endOfDay(start, calendar: calendar)
}

private func endOfDay(_ date: Date, calendar: Calendar) -> Date {
    let start = calendar.startOfDay(for: date)
    let next =
        calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
    return next.addingTimeInterval(-1)
}
