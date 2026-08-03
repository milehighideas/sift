import Foundation

public let launchdLabel = "com.brandonshutter.sift"

public enum LaunchdError: Error { case loadFailed(Int32) }

public func launchdPlistPath() -> String {
    expandTilde("~/Library/LaunchAgents/\(launchdLabel).plist")
}

/// The folders launchd should watch so a new arrival is handled within seconds
/// instead of at the next interval: configured folders that are not themselves
/// move destinations — and never the directory the log lives in.
///
/// Review and Delete are excluded because Sift's own moves into them would
/// re-trigger the agent. The log's directory is excluded for a sharper reason:
/// every run appends to the log, so watching that folder is a guaranteed
/// feedback loop (write → wake → run → write), bounded only by
/// ThrottleInterval. That is an invariant, not a config knob — there is no
/// setting under which watching it is correct.
public func watchPaths(for config: Config) -> [String] {
    let destinations = Set(
        config.folders.flatMap { folder in
            folder.rules.flatMap { rule in
                rule.actions.map { standardizePath($0.move.to) }
            }
        })
    let logDir = (standardizePath(config.settings.log) as NSString).deletingLastPathComponent
    return config.folders.map { standardizePath($0.path) }
        .filter { !destinations.contains($0) && $0 != logDir }
}

public func makeLaunchdPlist(
    binaryPath: String, configPath: String,
    interval: TimeInterval, logPath: String,
    watchPaths: [String]
) -> String {
    var dict: [String: Any] = [
        "Label": launchdLabel,
        "ProgramArguments": [binaryPath, "run", "--config", configPath],
        // StartInterval stays even with WatchPaths: the aging countdown has to
        // tick when nothing in the folders changes.
        "StartInterval": Int(interval),
        "RunAtLoad": true,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
        "ThrottleInterval": 30,
    ]
    if !watchPaths.isEmpty { dict["WatchPaths"] = watchPaths }
    guard
        let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0),
        let xml = String(data: data, encoding: .utf8)
    else {
        return ""
    }
    return xml
}

public func installAgent(binaryPath: String, configPath: String, config: Config) throws {
    let interval = try parseDuration(config.settings.interval)
    let plist = makeLaunchdPlist(
        binaryPath: binaryPath,
        configPath: expandTilde(configPath),
        interval: interval,
        logPath: expandTilde(config.settings.log),
        watchPaths: config.settings.optimize?.enabled == true ? watchPaths(for: config) : [])
    let path = launchdPlistPath()
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try plist.write(toFile: path, atomically: true, encoding: .utf8)
    _ = runLaunchctl(["unload", path])
    let rc = runLaunchctl(["load", path])
    if rc != 0 { throw LaunchdError.loadFailed(rc) }
}

public func uninstallAgent() throws {
    let path = launchdPlistPath()
    _ = runLaunchctl(["unload", path])
    try? FileManager.default.removeItem(atPath: path)
}

@discardableResult
private func runLaunchctl(_ args: [String]) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    do { try proc.run() } catch { return -1 }
    proc.waitUntilExit()
    return proc.terminationStatus
}
