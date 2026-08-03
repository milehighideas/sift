import Foundation

public struct Config: Codable {
    public let settings: Settings
    public let folders: [FolderConfig]
}

public struct Settings: Codable {
    public let interval: String
    public let log: String
    public let dryRun: Bool
    public let categories: [String: [String]]
    public let tagging: Tagging
    /// Optional: an absent block means the optimize pass is off. Must stay
    /// optional so configs written before the feature keep decoding.
    public let optimize: OptimizeSettings?
}

public struct Tagging: Codable {
    public let enabled: Bool
    public let prefix: String
}

public struct FolderConfig: Codable {
    public let path: String
    public let ignore: [String]?
    public let rules: [Rule]
}

public struct Rule: Codable {
    public let name: String
    public let match: String
    public let conditions: [Condition]
    public let actions: [Action]
}

public struct Condition: Codable {
    public let attr: String
    public let op: String
    public let value: String
}

public struct Action: Codable {
    public let move: MoveAction
}

public struct MoveAction: Codable {
    public let to: String
    public let sortInto: String
    public let onConflict: String
}

public enum ConfigError: Error, Equatable {
    case unreadable(String)
    case decode(String)
    case validation(String)
}

public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Normalizes a config path lexically: expands `~`, resolves `.` and `..`
/// segments, and collapses redundant separators.
///
/// Deliberately does **not** touch the filesystem. `NSString.standardizingPath`
/// resolves symlinks — including stripping a `/private` prefix — but only for
/// paths that already exist. Sift creates its own destination folders mid-pass,
/// so an existence-sensitive normalizer changes a folder's identity partway
/// through a run: the Review stage stops recognizing the destination it was
/// just handed, and the double-hop guard stops matching the paths it recorded.
/// Comparisons here are all between config-derived strings, so resolving
/// symlinks buys nothing and costs correctness.
public func standardizePath(_ path: String) -> String {
    let expanded = expandTilde(path)
    let isAbsolute = expanded.hasPrefix("/")
    var parts: [String] = []
    for segment in expanded.split(separator: "/") {
        switch segment {
        case ".":
            continue
        case "..":
            if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if !isAbsolute {
                parts.append("..")
            }
        default:
            parts.append(String(segment))
        }
    }
    let joined = parts.joined(separator: "/")
    if isAbsolute { return "/" + joined }
    return joined.isEmpty ? "." : joined
}

public func loadConfig(at path: String) throws -> Config {
    let url = URL(fileURLWithPath: expandTilde(path))
    guard let data = try? Data(contentsOf: url) else { throw ConfigError.unreadable(path) }
    let config: Config
    do {
        config = try JSONDecoder().decode(Config.self, from: data)
    } catch {
        throw ConfigError.decode("\(error)")
    }
    try validate(config)
    return config
}

func validate(_ c: Config) throws {
    do { _ = try parseDuration(c.settings.interval) } catch {
        throw ConfigError.validation("bad settings.interval: \(c.settings.interval)")
    }

    if let optimize = c.settings.optimize {
        guard (0...6).contains(optimize.level) else {
            throw ConfigError.validation("bad optimize.level: \(optimize.level) (expected 0-6)")
        }
        guard !optimize.skipTag.isEmpty else {
            throw ConfigError.validation("optimize.skipTag must not be empty")
        }
    }

    for folder in c.folders {
        guard folder.rules.count <= 1 else {
            throw ConfigError.validation(
                "folder \(folder.path) has more than one rule; v1 supports one rule per folder")
        }
        for rule in folder.rules {
            guard ["all", "any"].contains(rule.match) else {
                throw ConfigError.validation("bad rule.match: \(rule.match)")
            }
            guard rule.actions.count <= 1 else {
                throw ConfigError.validation(
                    "rule \(rule.name) has more than one action; v1 supports one action per rule")
            }
            for cond in rule.conditions {
                guard cond.attr == "date_added" else {
                    throw ConfigError.validation("unsupported attr: \(cond.attr)")
                }
                guard cond.op == "older_than" else {
                    throw ConfigError.validation("unsupported op: \(cond.op)")
                }
                do { _ = try parseDuration(cond.value) } catch {
                    throw ConfigError.validation("bad condition value: \(cond.value)")
                }
            }
            for action in rule.actions {
                guard ["category", "none"].contains(action.move.sortInto) else {
                    throw ConfigError.validation("bad sortInto: \(action.move.sortInto)")
                }
                guard ["rename", "replace", "skip"].contains(action.move.onConflict) else {
                    throw ConfigError.validation("bad onConflict: \(action.move.onConflict)")
                }
            }
        }
    }
}
