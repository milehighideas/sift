import Foundation

public let launchdLabel = "com.brandonshutter.sift"

public enum LaunchdError: Error { case loadFailed(Int32) }

public func launchdPlistPath() -> String {
    expandTilde("~/Library/LaunchAgents/\(launchdLabel).plist")
}

public func makeLaunchdPlist(binaryPath: String, configPath: String,
                             interval: TimeInterval, logPath: String) -> String {
    let dict: [String: Any] = [
        "Label": launchdLabel,
        "ProgramArguments": [binaryPath, "run", "--config", configPath],
        "StartInterval": Int(interval),
        "RunAtLoad": true,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
          let xml = String(data: data, encoding: .utf8) else {
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
        logPath: expandTilde(config.settings.log))
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
