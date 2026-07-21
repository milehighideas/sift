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
}

public struct Tagging: Codable {
    public let enabled: Bool
    public let prefix: String
}

public struct FolderConfig: Codable {
    public let path: String
    public let recurse: Bool
    public let filesOnly: Bool
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
    do { _ = try parseDuration(c.settings.interval) }
    catch { throw ConfigError.validation("bad settings.interval: \(c.settings.interval)") }

    for folder in c.folders {
        for rule in folder.rules {
            guard ["all", "any"].contains(rule.match) else {
                throw ConfigError.validation("bad rule.match: \(rule.match)")
            }
            for cond in rule.conditions {
                guard cond.attr == "date_added" else {
                    throw ConfigError.validation("unsupported attr: \(cond.attr)")
                }
                guard cond.op == "older_than" else {
                    throw ConfigError.validation("unsupported op: \(cond.op)")
                }
                do { _ = try parseDuration(cond.value) }
                catch { throw ConfigError.validation("bad condition value: \(cond.value)") }
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
