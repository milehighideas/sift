import Foundation

public enum DurationError: Error, Equatable {
    case empty
    case badFormat(String)
    case badUnit(Character)
}

/// Parses a duration string like "7d", "1h", "30m", "90s" into seconds.
public func parseDuration(_ s: String) throws -> TimeInterval {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard let unit = trimmed.last else { throw DurationError.empty }
    let numberPart = String(trimmed.dropLast())
    guard let value = Double(numberPart) else { throw DurationError.badFormat(trimmed) }
    guard value.isFinite, value >= 0 else { throw DurationError.badFormat(trimmed) }
    switch unit {
    case "s": return value
    case "m": return value * 60
    case "h": return value * 3600
    case "d": return value * 86400
    default: throw DurationError.badUnit(unit)
    }
}
