import Darwin
import Foundation

public struct Logger {
    public let path: String
    /// Whether to echo messages to stdout as well as the log file.
    ///
    /// Defaults to "only when stdout is a terminal". Under launchd, stdout is
    /// redirected to this very file (`StandardOutPath`), so echoing there
    /// writes every message twice through two file descriptors with
    /// independent offsets — they interleave and truncate each other, which
    /// corrupted 110 lines of the production log before this was caught.
    public let echo: Bool

    public init(path: String, echo: Bool? = nil) {
        self.path = expandTilde(path)
        self.echo = echo ?? (isatty(STDOUT_FILENO) != 0)
    }

    public func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        if echo { print(message) }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
