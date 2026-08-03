import Foundation

public func defaultConfigPath() -> String {
    expandTilde("~/.config/sift/sift.json")
}

public struct ParsedArgs: Equatable {
    public let command: String
    public let configPath: String
    public let dryRun: Bool
    public let outPath: String?
    public let openAfter: Bool

    public init(
        command: String, configPath: String, dryRun: Bool, outPath: String? = nil,
        openAfter: Bool = false
    ) {
        self.command = command
        self.configPath = configPath
        self.dryRun = dryRun
        self.outPath = outPath
        self.openAfter = openAfter
    }
}

public func parseArgs(_ argv: [String]) -> ParsedArgs {
    var command = ""
    var configPath = defaultConfigPath()
    var dryRun = false
    var outPath: String?
    var openAfter = false
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--config":
            if i + 1 < argv.count {
                configPath = argv[i + 1]
                i += 1
            }
        case "--out":
            if i + 1 < argv.count {
                outPath = argv[i + 1]
                i += 1
            }
        case "--open":
            openAfter = true
        case "--dry-run":
            dryRun = true
        case "--help", "-h", "help":
            command = "help"
        default:
            if command.isEmpty && !arg.hasPrefix("-") { command = arg }
        }
        i += 1
    }
    return ParsedArgs(
        command: command, configPath: configPath, dryRun: dryRun, outPath: outPath,
        openAfter: openAfter)
}

private func printUsage(to handle: FileHandle) {
    let usage = """
        sift — file aging automation

        Usage: sift <command> [--config <path>] [--dry-run]

        Commands:
          run         Perform one scan pass (moves/tags files)
          status      Show what would move and each file's countdown (no changes)
          report      Write an HTML report of folders, rules, and activity
          install     Install and load the launchd agent
          uninstall   Unload and remove the launchd agent
          help        Show this help

        Options:
          --config <path>   Config file (default: ~/.config/sift/sift.json)
          --dry-run         Log actions without changing anything
          --out <path>      Report output path
                            (default: ~/Library/Caches/com.brandonshutter.sift/report.html)
          --open            Open the report when done

        """
    handle.write(Data(usage.utf8))
}

public func runCLI(_ argv: [String]) -> Int32 {
    let args = parseArgs(argv)
    switch args.command {
    case "run": return cmdRun(args, statusOnly: false)
    case "status": return cmdRun(args, statusOnly: true)
    case "report": return cmdReport(args)
    case "install": return cmdInstall(args)
    case "uninstall": return cmdUninstall()
    case "help":
        printUsage(to: FileHandle.standardOutput)
        return 0
    case "":
        FileHandle.standardError.write(Data("sift: no command given\n".utf8))
        printUsage(to: FileHandle.standardError)
        return 2
    default:
        FileHandle.standardError.write(Data("sift: unknown command '\(args.command)'\n".utf8))
        printUsage(to: FileHandle.standardError)
        return 2
    }
}

private func loadOrReport(_ path: String) -> Config? {
    do { return try loadConfig(at: path) } catch {
        FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
        return nil
    }
}

private func cmdRun(_ args: ParsedArgs, statusOnly: Bool) -> Int32 {
    guard let config = loadOrReport(args.configPath) else { return 1 }
    let dryRun = statusOnly || args.dryRun || config.settings.dryRun
    let logger = Logger(path: config.settings.log)
    let sink: (String) -> Void = statusOnly ? { print($0) } : { logger.log($0) }
    // Dry runs stay byte-for-byte read-only: the appender is wired only for a
    // real pass, so `.pending` events never reach disk.
    let events = EventLog(path: eventLogPath(for: config))
    let eventSink: (SiftEvent) -> Void = dryRun ? { _ in } : { events.append($0) }
    // Optimize first: a new arrival is shrunk before it can ever be moved, and
    // the pass restores Date Added so aging behaves identically either way.
    if let optimize = config.settings.optimize, optimize.enabled {
        OptimizePass(config: config, dryRun: dryRun, log: sink, event: eventSink).run()
    }
    Scanner(config: config, now: Date(), dryRun: dryRun, log: sink, event: eventSink).run()
    return 0
}

private func cmdReport(_ args: ParsedArgs) -> Int32 {
    guard let config = loadOrReport(args.configPath) else { return 1 }
    // A dry-run pass produces `.pending` through the real Scanner, so "due
    // next" can never drift from what an actual run would do.
    var pending: [SiftEvent] = []
    Scanner(
        config: config, now: Date(), dryRun: true, log: { _ in },
        event: { if $0.kind == .pending { pending.append($0) } }
    ).run()
    let logDir = (standardizePath(config.settings.log) as NSString).deletingLastPathComponent
    let history = readAllEvents(logDirectory: logDir).filter { $0.kind != .pending }
    let html = renderReport(
        ReportData(config: config, pending: pending, history: history), generated: Date())

    let outPath = expandTilde(args.outPath ?? defaultReportPath())
    let url = URL(fileURLWithPath: outPath)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("report failed: \(error)\n".utf8))
        return 1
    }
    print(outPath)
    if args.openAfter {
        _ = runProcess("/usr/bin/open", [outPath], timeout: 10)
    }
    return 0
}

private func cmdInstall(_ args: ParsedArgs) -> Int32 {
    guard let config = loadOrReport(args.configPath) else { return 1 }
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    do {
        try installAgent(binaryPath: binary, configPath: args.configPath, config: config)
        print("installed \(launchdLabel)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        return 1
    }
}

private func cmdUninstall() -> Int32 {
    do {
        try uninstallAgent()
        print("uninstalled \(launchdLabel)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
        return 1
    }
}
