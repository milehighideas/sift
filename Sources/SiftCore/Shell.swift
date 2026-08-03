import Darwin
import Foundation

public struct ShellResult {
    public let status: Int32
    public let timedOut: Bool
}

/// Runs an external tool to completion with a hard timeout. Output is
/// discarded — callers judge success by exit status plus their own inspection
/// of any files the tool wrote. On timeout the process is terminated (then
/// SIGKILLed if it ignores that); the launchd agent must never wedge on one
/// stuck subprocess, because launchd will not start a second instance of the
/// label while it runs.
public func runProcess(
    _ launchPath: String, _ arguments: [String], timeout: TimeInterval
) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch {
        return ShellResult(status: -1, timedOut: false)
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if done.wait(timeout: .now() + 5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 5)
        }
        return ShellResult(status: -1, timedOut: true)
    }
    return ShellResult(status: process.terminationStatus, timedOut: false)
}
