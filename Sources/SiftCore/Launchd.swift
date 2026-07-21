import Foundation

public let launchdLabel = "com.brandonshutter.sift"

public func launchdPlistPath() -> String {
    expandTilde("~/Library/LaunchAgents/\(launchdLabel).plist")
}

public func makeLaunchdPlist(binaryPath: String, configPath: String,
                             interval: TimeInterval, logPath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(launchdLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(binaryPath)</string>
            <string>run</string>
            <string>--config</string>
            <string>\(configPath)</string>
        </array>
        <key>StartInterval</key>
        <integer>\(Int(interval))</integer>
        <key>RunAtLoad</key>
        <true/>
        <key>StandardOutPath</key>
        <string>\(logPath)</string>
        <key>StandardErrorPath</key>
        <string>\(logPath)</string>
    </dict>
    </plist>
    """
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
    _ = runLaunchctl(["load", path])
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
    try? proc.run()
    proc.waitUntilExit()
    return proc.terminationStatus
}
