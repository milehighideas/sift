import Foundation

public func isOlderThan(dateAdded: Date, threshold: TimeInterval, now: Date) -> Bool {
    now.timeIntervalSince(dateAdded) > threshold
}

/// Whole days until the file ages out. Returns 0 when it should move now,
/// otherwise the ceiling of the remaining time in days, clamped to at least 1.
public func remainingDays(dateAdded: Date, threshold: TimeInterval, now: Date) -> Int {
    let elapsed = max(0, now.timeIntervalSince(dateAdded))
    let remaining = threshold - elapsed
    if remaining <= 0 { return 0 }
    return max(Int(ceil(remaining / 86400)), 1)
}

public func ruleMatches(_ rule: Rule, dateAdded: Date, now: Date) throws -> Bool {
    let results = try rule.conditions.map { cond -> Bool in
        let threshold = try parseDuration(cond.value)
        return isOlderThan(dateAdded: dateAdded, threshold: threshold, now: now)
    }
    switch rule.match {
    case "all": return results.allSatisfy { $0 }
    case "any": return results.contains(true)
    default: return false
    }
}
