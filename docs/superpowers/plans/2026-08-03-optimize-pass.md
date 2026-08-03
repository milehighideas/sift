# Optimize Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A lossless, format-pluggable optimization pass that runs before aging, skips `Keep OG`-tagged files, marks processed files `Sift · Optimized`, and fires immediately on new arrivals via launchd WatchPaths.

**Architecture:** New `OptimizePass` walks all watched folders plus their move destinations and pushes each candidate through a uniform temp-file pipeline (tool writes a temp output → verify → atomic rename → restore Date Added + xattrs → marker tag). Per-format behavior lives in a `FileOptimizer` registry; everything else is format-neutral so PDF later is one registry entry.

**Tech Stack:** Swift 5.9, Foundation + Darwin + ImageIO/CoreGraphics only (both are system frameworks — zero SwiftPM deps). External CLI tools (`oxipng`, `jpegtran`, `gifsicle`) discovered at runtime.

**Spec:** `docs/superpowers/specs/2026-08-03-optimize-pass-design.md` — read it first.

## Global Constraints

- Zero SwiftPM dependencies; `Package.swift` is not touched.
- swift-format is pinned: run `swift-format format -i -r Sources Tests` before every commit; pre-commit runs `lint --strict` plus build and tests.
- Existing behavior invariants (whole-item moves, double-hop guard, clamped age, restamp-on-move, tag preservation) must keep passing — the full suite runs on every commit via the hook.
- The deployed `~/.config/sift/sift.json` has no `optimize` block: every config change must keep a block-less config decoding and validating.
- Optimizer tool invocations, verbatim from the spec: oxipng `--out <out> --force -o <level> --strip safe <in>`; jpegtran `-copy all -optimize -progressive -outfile <out> <in>`; gifsicle `-O2 -o <out> <in>`.
- Failure direction is always "leave the original alone". The marker is written only on success or on verified not-smaller.
- Marker tag text is `<prefix> · Optimized`, color 2 (green). Skip tag default `Keep OG`.
- Subprocess tests use stub shell scripts written by the test; nothing in the suite may require oxipng/jpegtran/gifsicle to be installed (real-tool tests gate on `XCTSkipUnless`).

---

### Task 1: `Shell.swift` — subprocess runner with hard timeout

**Files:**
- Create: `Sources/SiftCore/Shell.swift`
- Test: `Tests/SiftCoreTests/ShellTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct ShellResult { public let status: Int32; public let timedOut: Bool }` and `public func runProcess(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> ShellResult`. Task 6 calls this for every optimizer invocation.

- [ ] **Step 1: Write the failing tests**

`Tests/SiftCoreTests/ShellTests.swift`:

```swift
import XCTest

@testable import SiftCore

final class ShellTests: XCTestCase {
    func testCapturesExitStatus() {
        let r = runProcess("/bin/sh", ["-c", "exit 3"], timeout: 10)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.timedOut)
    }

    func testZeroExit() {
        let r = runProcess("/bin/sh", ["-c", "true"], timeout: 10)
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.timedOut)
    }

    func testTimeoutKillsProcess() {
        let start = Date()
        let r = runProcess("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        // Came back promptly, not after 30s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingBinaryReportsFailure() {
        let r = runProcess("/no/such/tool", [], timeout: 5)
        XCTAssertEqual(r.status, -1)
        XCTAssertFalse(r.timedOut)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.ShellTests`
Expected: compile FAILURE — `runProcess` not defined.

- [ ] **Step 3: Implement**

`Sources/SiftCore/Shell.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SiftCoreTests.ShellTests`
Expected: 4 tests PASS (timeout test takes ~0.5–5s).

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Shell.swift Tests/SiftCoreTests/ShellTests.swift
git commit -m "feat(shell): add subprocess runner with hard timeout"
```

---

### Task 2: `FSMetadata` — xattr capture/restore and `addSiftTag`

**Files:**
- Modify: `Sources/SiftCore/FSMetadata.swift` (append after `setSiftTag`)
- Test: `Tests/SiftCoreTests/FSMetadataTests.swift` (append cases)

**Interfaces:**
- Consumes: existing `rawTags(of:)`, `FSMetaError`, private `tagsXattr`.
- Produces:
  - `public func captureXattrs(of path: String) -> [(name: String, data: Data)]`
  - `@discardableResult public func restoreXattrs(_ attrs: [(name: String, data: Data)], to path: String) -> Bool` (false = at least one setxattr failed)
  - `public func addSiftTag(_ path: String, text: String, color: Int) throws` — idempotent append; removes only an existing entry with the same name.
  Task 6 uses all three around the atomic replace.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SiftCoreTests/FSMetadataTests.swift`:

```swift
    func testXattrCaptureRestoreRoundTrip() throws {
        let src = try tempFile()
        let dst = try tempFile()
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        try setSiftTag(
            src, text: "Sift · 3d → Delete", color: 7, prefix: "Sift",
            preserving: { _ in false })
        let attrs = captureXattrs(of: src)
        XCTAssertFalse(attrs.isEmpty)
        XCTAssertTrue(restoreXattrs(attrs, to: dst))
        XCTAssertEqual(rawTags(of: dst), rawTags(of: src))
    }

    func testCaptureXattrsEmptyForPlainFile() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(captureXattrs(of: path).isEmpty)
    }

    func testAddSiftTagAppendsWithoutTouchingOthers() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try setSiftTag(
            path, text: "Sift · 3d → Delete", color: 7, prefix: "Sift",
            preserving: { _ in false })
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        let tags = rawTags(of: path)
        XCTAssertTrue(tags.contains("Sift · Optimized\n2"))
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · 3d → Delete") })
    }

    func testAddSiftTagIsIdempotent() throws {
        let path = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        let markers = rawTags(of: path).filter { $0.hasPrefix("Sift · Optimized") }
        XCTAssertEqual(markers.count, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.FSMetadataTests`
Expected: compile FAILURE — `captureXattrs` not defined.

- [ ] **Step 3: Implement**

Append to `Sources/SiftCore/FSMetadata.swift`:

```swift
/// All extended attributes of a file, raw. Captured before an optimize
/// replaces the file and restored after, so Finder tags (countdown, pins,
/// user tags) and anything else survive the swap.
public func captureXattrs(of path: String) -> [(name: String, data: Data)] {
    let size = listxattr(path, nil, 0, 0)
    if size <= 0 { return [] }
    var nameBuf = [CChar](repeating: 0, count: size)
    let read = listxattr(path, &nameBuf, size, 0)
    if read <= 0 { return [] }
    let names = nameBuf[..<Int(read)].split(separator: 0).compactMap {
        String(bytes: $0.map { UInt8(bitPattern: $1) }, encoding: .utf8)
    }
    var out: [(name: String, data: Data)] = []
    for name in names {
        let vsize = getxattr(path, name, nil, 0, 0, 0)
        if vsize < 0 { continue }
        var data = Data(count: vsize)
        let vread = data.withUnsafeMutableBytes { buf in
            getxattr(path, name, buf.baseAddress, vsize, 0, 0)
        }
        if vread >= 0 { out.append((name, data.prefix(vread))) }
    }
    return out
}

/// Best-effort restore; returns false if any attribute failed to write.
@discardableResult
public func restoreXattrs(_ attrs: [(name: String, data: Data)], to path: String) -> Bool {
    var ok = true
    for (name, data) in attrs {
        let rc = data.withUnsafeBytes { buf in
            setxattr(path, name, buf.baseAddress, buf.count, 0, 0)
        }
        if rc != 0 { ok = false }
    }
    return ok
}

/// Appends one Sift tag without disturbing any other entry. Idempotent:
/// an existing entry with the same name is replaced, nothing else is
/// touched. Used for persistent markers (`Sift · Optimized`), where
/// `setSiftTag`'s replace-the-transient-tags semantics would be wrong.
public func addSiftTag(_ path: String, text: String, color: Int) throws {
    var tags = rawTags(of: path).filter { entry in
        (entry.components(separatedBy: "\n").first ?? entry) != text
    }
    tags.append("\(text)\n\(color)")
    let data = try PropertyListSerialization.data(
        fromPropertyList: tags, format: .binary, options: 0)
    let rc = data.withUnsafeBytes { buf in
        setxattr(path, tagsXattr, buf.baseAddress, buf.count, 0, 0)
    }
    if rc != 0 { throw FSMetaError.setxattr(errno) }
}
```

Note: the `nameBuf` iteration maps `CChar` (Int8) slices to `UInt8` — the
`$1` in the compactMap closure is the element of the split slice. If the
compiler fights the closure, use the explicit loop form:

```swift
    var names: [String] = []
    var start = 0
    for i in 0..<Int(read) where nameBuf[i] == 0 {
        let bytes = nameBuf[start..<i].map { UInt8(bitPattern: $0) }
        if let s = String(bytes: bytes, encoding: .utf8) { names.append(s) }
        start = i + 1
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SiftCoreTests.FSMetadataTests`
Expected: all PASS (7 existing + 4 new).

- [ ] **Step 5: Format, run full suite, commit**

```bash
swift-format format -i -r Sources Tests
swift test
git add Sources/SiftCore/FSMetadata.swift Tests/SiftCoreTests/FSMetadataTests.swift
git commit -m "feat(fsmetadata): xattr capture/restore and idempotent addSiftTag"
```

---

### Task 3: Tag vocabulary — `Keep OG` carve-out, `isOptimizedTag`, `isPersistentSiftTag`, Scanner predicate fixes

This task closes the measured trap (`Sift · Keep OG` pinned forever + tag erased)
and fixes two latent marker-eaters in Scanner: `writeKeepTag` and `retirePin`
both call `setSiftTag` with `preserving: { _ in false }`, which would strip a
`Sift · Optimized` marker; and `clearStaleCountdown`'s stale check would treat
the marker as a stale countdown and rewrite tags every pass.

**Files:**
- Modify: `Sources/SiftCore/Keep.swift`
- Modify: `Sources/SiftCore/Scanner.swift` (`keepPredicate`, `writeKeepTag`, `retirePin`, `clearStaleCountdown`)
- Test: `Tests/SiftCoreTests/KeepTests.swift`, `Tests/SiftCoreTests/ScannerTests.swift` (append)

**Interfaces:**
- Consumes: existing `isKeepTag`, `parseKeepTag`, private `keepBody`.
- Produces (Task 6 depends on all three):
  - `public func isKeepOGTag(_ entry: String, prefix: String, skipTag: String) -> Bool` — true for a bare entry equal to `skipTag` and for `<prefix> · Keep OG`.
  - `public func isOptimizedTag(_ entry: String, prefix: String) -> Bool` — true for `<prefix> · Optimized`.
  - `public func isPersistentSiftTag(_ entry: String, prefix: String) -> Bool` — `isKeepTag || isOptimizedTag`; the one predicate for `setSiftTag(preserving:)`.
  - Changed behavior: `parseKeepTag` returns nil (not `.malformed`) for a body of exactly `OG`; a file with both `Sift · Keep OG` and a real pin still parses the pin.

- [ ] **Step 1: Write the failing tests**

Append to `KeepTests.swift`:

```swift
    // MARK: - Keep OG carve-out

    func testKeepOGIsNotAPin() {
        XCTAssertNil(parseKeepTag(["Sift · Keep OG"], prefix: "Sift", calendar: cal))
        XCTAssertNil(parseKeepTag(["Sift · Keep OG\n6"], prefix: "Sift", calendar: cal))
    }

    func testKeepOGEntryIsSkippedButRealPinStillFound() {
        let tags = ["Sift · Keep OG", "Sift · Keep 30d"]
        XCTAssertEqual(
            parseKeepTag(tags, prefix: "Sift", calendar: cal), .relative(30 * 86400))
    }

    func testIsKeepOGTagMatrix() {
        XCTAssertTrue(isKeepOGTag("Keep OG", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertTrue(isKeepOGTag("Keep OG\n3", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertTrue(isKeepOGTag("Sift · Keep OG", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertTrue(isKeepOGTag("Original", prefix: "Sift", skipTag: "Original"))
        XCTAssertFalse(isKeepOGTag("Keep OG extra", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertFalse(isKeepOGTag("Sift · Keep", prefix: "Sift", skipTag: "Keep OG"))
        XCTAssertFalse(isKeepOGTag("Sift · Keepsakes", prefix: "Sift", skipTag: "Keep OG"))
    }

    func testKeepOGStillCountsAsKeepTagForPreservation() {
        XCTAssertTrue(isKeepTag("Sift · Keep OG", prefix: "Sift"))
    }

    // MARK: - Persistent-tag predicate

    func testIsOptimizedTag() {
        XCTAssertTrue(isOptimizedTag("Sift · Optimized", prefix: "Sift"))
        XCTAssertTrue(isOptimizedTag("Sift · Optimized\n2", prefix: "Sift"))
        XCTAssertFalse(isOptimizedTag("Optimized", prefix: "Sift"))
        XCTAssertFalse(isOptimizedTag("Sift · Optimize", prefix: "Sift"))
    }

    func testPersistentSiftTagMatrix() {
        for yes in [
            "Sift · Keep", "Sift · Keep 30d\n6", "Sift · Keep until 2026-09-02",
            "Sift · Keep OG", "Sift · Optimized\n2",
        ] {
            XCTAssertTrue(isPersistentSiftTag(yes, prefix: "Sift"), yes)
        }
        for no in ["Sift · 3d → Delete\n7", "Sift · Delete", "Work", "Sift · Keepsakes"] {
            XCTAssertFalse(isPersistentSiftTag(no, prefix: "Sift"), no)
        }
    }
```

Append to `ScannerTests.swift` (Keep pin section):

```swift
    func testKeepOGTaggedFileAgesNormally() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep OG")
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        // Keep OG is not a pin: the file moves, and the tag survives the move.
        let moved = home.appendingPathComponent("Desktop/Desktop to Review/Images/old.png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))
        XCTAssertTrue(rawTags(of: moved).contains { $0.hasPrefix("Sift · Keep OG") })
    }

    func testOptimizedMarkerSurvivesPinNormalizationAndRetirement() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try setSiftTag(
            path, text: "Sift · Keep until \(isoDay(offsetDays: -2))", color: 6,
            prefix: "Sift", preserving: { isPersistentSiftTag($0, prefix: "Sift") })
        Scanner(config: config(), now: Date(), dryRun: false, log: { _ in }).run()
        // Pin retired (tag gone, clock restamped) but the marker survives.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let tags = rawTags(of: path)
        XCTAssertFalse(tags.contains { $0.hasPrefix("Sift · Keep") })
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testPinnedFileWithMarkerIsSteadyState() throws {
        let path = try makeFile("Desktop/Desktop to Review/Images/old.png", addedDaysAgo: 1)
        try addSiftTag(path, text: "Sift · Optimized", color: 2)
        try setSiftTag(
            path, text: "Sift · Keep", color: 6, prefix: "Sift",
            preserving: { isPersistentSiftTag($0, prefix: "Sift") })
        var logs: [String] = []
        Scanner(config: config(), now: Date(), dryRun: false, log: { logs.append($0) }).run()
        // The marker must not be mistaken for a stale countdown: no writes.
        XCTAssertFalse(logs.contains { $0.hasPrefix("UNTAG") })
        XCTAssertTrue(rawTags(of: path).contains { $0.hasPrefix("Sift · Optimized") })
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.KeepTests && swift test --filter SiftCoreTests.ScannerTests`
Expected: compile FAILURE — `isKeepOGTag` / `isOptimizedTag` / `isPersistentSiftTag` not defined.

- [ ] **Step 3: Implement Keep.swift changes**

In `Keep.swift`, change the loop in `parseKeepTag` to skip OG bodies:

```swift
public func parseKeepTag(_ entries: [String], prefix: String, calendar: Calendar) -> KeepTag? {
    for entry in entries {
        if let body = keepBody(entry, prefix: prefix) {
            // "Keep OG" is the keep-the-original marker, not a pin.
            if body == keepOGBody { continue }
            return parseKeepBody(body, calendar: calendar)
        }
    }
    return nil
}
```

Add near the other constants and public functions:

```swift
private let keepOGBody = "OG"
private let optimizedToken = "Optimized"

/// The name portion of a tag entry, without the "\n<colorIndex>" suffix.
private func tagName(_ entry: String) -> String {
    entry.components(separatedBy: "\n").first ?? entry
}

/// True when a tag entry means "keep the original file contents" — either the
/// bare configured skip tag, or the namespaced `<prefix> · Keep OG` form.
public func isKeepOGTag(_ entry: String, prefix: String, skipTag: String) -> Bool {
    let name = tagName(entry)
    return name == skipTag || name == "\(prefix) · \(keepToken) \(keepOGBody)"
}

/// True for the `<prefix> · Optimized` idempotency marker.
public func isOptimizedTag(_ entry: String, prefix: String) -> Bool {
    tagName(entry) == "\(prefix) · \(optimizedToken)"
}

/// Sift's persistent tags — every Keep form plus the Optimized marker. This is
/// the predicate `setSiftTag(preserving:)` callers use so that rewriting a
/// transient tag (countdown/terminal) never strips durable state.
public func isPersistentSiftTag(_ entry: String, prefix: String) -> Bool {
    isKeepTag(entry, prefix: prefix) || isOptimizedTag(entry, prefix: prefix)
}
```

(`keepBody` already strips the `\n` suffix via its own `components(separatedBy:)`;
`isKeepTag("Sift · Keep OG")` is therefore already true and stays true.)

- [ ] **Step 4: Fix the four Scanner call sites**

In `Scanner.swift`:

1. `keepPredicate` becomes the shared persistent predicate:

```swift
    private var keepPredicate: (String) -> Bool {
        let prefix = config.settings.tagging.prefix
        return { isPersistentSiftTag($0, prefix: prefix) }
    }
```

2. In `retirePin`, replace `preserving: { _ in false }` with a predicate that
   drops Keep tags but keeps the marker:

```swift
            try setSiftTag(
                item.path, text: nil, color: 0, prefix: config.settings.tagging.prefix,
                preserving: { isOptimizedTag($0, prefix: self.config.settings.tagging.prefix) })
```

(If the compiler rejects `self` capture in the struct context, hoist
`let prefix = config.settings.tagging.prefix` above the `do` and use
`{ isOptimizedTag($0, prefix: prefix) }`.)

3. In `writeKeepTag`, same replacement for its `preserving: { _ in false }`:

```swift
        let prefix = config.settings.tagging.prefix
        ...
            try setSiftTag(
                item.path, text: text, color: 6, prefix: prefix,
                preserving: { isOptimizedTag($0, prefix: prefix) })
```

4. In `clearStaleCountdown`, the stale check must not count persistent tags:

```swift
        let stale = tags.contains { entry in
            let name = entry.components(separatedBy: "\n").first ?? entry
            return name.hasPrefix(prefix + " · ") && !isPersistentSiftTag(entry, prefix: prefix)
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: full suite PASS (existing 78 + new). Pay attention to the existing
Keep tests — `testUnparseableDurationIsMalformed` etc. must still pass; only
the exact body `OG` is carved out.

- [ ] **Step 6: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Keep.swift Sources/SiftCore/Scanner.swift \
        Tests/SiftCoreTests/KeepTests.swift Tests/SiftCoreTests/ScannerTests.swift
git commit -m "feat(keep): Keep OG carve-out and persistent-tag predicate

Sift · Keep OG no longer parses as a malformed pin (it is the
keep-the-original marker). isPersistentSiftTag unifies preservation of
Keep tags and the upcoming Sift · Optimized marker; retirePin,
writeKeepTag, and clearStaleCountdown no longer eat the marker."
```

---

### Task 4: `Optimize.swift` — settings, registry, discovery, image verify

**Files:**
- Create: `Sources/SiftCore/Optimize.swift`
- Test: `Tests/SiftCoreTests/OptimizeTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (Tasks 5–7 depend on these exact names):
  - `public struct OptimizeSettings: Codable { enabled: Bool, skipTag: String, level: Int }` with decode defaults `"Keep OG"` / `2` and a memberwise `public init(enabled:skipTag:level:)` with the same defaults.
  - `public enum VerifyResult: Equatable { case ok, originalUnreadable, candidateInvalid }`
  - `public struct FileOptimizer { name: String, extensions: Set<String>, toolNames: [String], arguments: (String, String, Int) -> [String], verify: (URL, URL) -> VerifyResult }` (arguments = input path, output path, level)
  - `public let imageOptimizers: [FileOptimizer]` (order: png, jpeg, gif)
  - `public let imageOptimResourcesDir: String`
  - `public func defaultToolSearchDirs(environment: [String: String]) -> [String]`
  - `public func findTool(named name: String, searchDirs: [String]) -> String?`
  - `public func verifyImage(original: URL, candidate: URL) -> VerifyResult`

- [ ] **Step 1: Write the failing tests**

`Tests/SiftCoreTests/OptimizeTests.swift`:

```swift
import CoreGraphics
import ImageIO
import XCTest

@testable import SiftCore

final class OptimizeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // Shared with OptimizePassTests via @testable target membership.
    static func writePNG(to url: URL, width: Int = 16, height: Int = 16) throws {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 1)
        }
    }

    // MARK: - Settings decoding

    func testSettingsDecodeWithDefaults() throws {
        let json = Data(#"{"enabled": true}"#.utf8)
        let s = try JSONDecoder().decode(OptimizeSettings.self, from: json)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.skipTag, "Keep OG")
        XCTAssertEqual(s.level, 2)
    }

    func testSettingsDecodeExplicit() throws {
        let json = Data(#"{"enabled": false, "skipTag": "Original", "level": 4}"#.utf8)
        let s = try JSONDecoder().decode(OptimizeSettings.self, from: json)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.skipTag, "Original")
        XCTAssertEqual(s.level, 4)
    }

    // MARK: - Registry

    func testRegistryCoversExpectedFormats() {
        let names = imageOptimizers.map(\.name)
        XCTAssertEqual(names, ["png", "jpeg", "gif"])
        let exts = Set(imageOptimizers.flatMap(\.extensions))
        XCTAssertEqual(exts, ["png", "jpg", "jpeg", "gif"])
    }

    func testArgumentConstruction() {
        let png = imageOptimizers[0]
        XCTAssertEqual(
            png.arguments("/a/in.png", "/a/out.png", 2),
            ["--out", "/a/out.png", "--force", "-o", "2", "--strip", "safe", "/a/in.png"])
        let jpeg = imageOptimizers[1]
        XCTAssertEqual(
            jpeg.arguments("/a/in.jpg", "/a/out.jpg", 2),
            ["-copy", "all", "-optimize", "-progressive", "-outfile", "/a/out.jpg", "/a/in.jpg"])
        let gif = imageOptimizers[2]
        XCTAssertEqual(
            gif.arguments("/a/in.gif", "/a/out.gif", 2), ["-O2", "-o", "/a/out.gif", "/a/in.gif"])
    }

    // MARK: - Tool discovery

    func testFindToolPrefersEarlierDirs() throws {
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        for d in [a, b] {
            let tool = d.appendingPathComponent("faketool")
            try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        XCTAssertEqual(
            findTool(named: "faketool", searchDirs: [a.path, b.path]),
            a.appendingPathComponent("faketool").path)
    }

    func testFindToolSkipsNonExecutable() throws {
        let tool = dir.appendingPathComponent("notexec")
        try "x".write(to: tool, atomically: true, encoding: .utf8)
        XCTAssertNil(findTool(named: "notexec", searchDirs: [dir.path]))
    }

    func testFindToolMissingReturnsNil() {
        XCTAssertNil(findTool(named: "no-such-tool-xyz", searchDirs: [dir.path]))
    }

    func testDefaultSearchDirsSplitsPathAndAppendsImageOptim() {
        let dirs = defaultToolSearchDirs(environment: ["PATH": "/usr/bin:/opt/x/bin"])
        XCTAssertEqual(dirs, ["/usr/bin", "/opt/x/bin", imageOptimResourcesDir])
    }

    // MARK: - Image verify

    func testVerifyOkForIdenticalDimensionPNGs() throws {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try Self.writePNG(to: a)
        try Self.writePNG(to: b)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .ok)
    }

    func testVerifyRejectsTruncatedCandidate() throws {
        let a = dir.appendingPathComponent("a.png")
        try Self.writePNG(to: a)
        let full = try Data(contentsOf: a)
        let b = dir.appendingPathComponent("b.png")
        try full.prefix(full.count / 3).write(to: b)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyRejectsDimensionMismatch() throws {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try Self.writePNG(to: a, width: 16, height: 16)
        try Self.writePNG(to: b, width: 8, height: 8)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .candidateInvalid)
    }

    func testVerifyFlagsUnreadableOriginal() throws {
        let a = dir.appendingPathComponent("a.png")
        try Data("not an image".utf8).write(to: a)
        let b = dir.appendingPathComponent("b.png")
        try Self.writePNG(to: b)
        XCTAssertEqual(verifyImage(original: a, candidate: b), .originalUnreadable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.OptimizeTests`
Expected: compile FAILURE — types not defined.

- [ ] **Step 3: Implement**

`Sources/SiftCore/Optimize.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO

/// Settings for the optimize pass. Optional in config: an absent block means
/// the feature is off; absent fields default (`skipTag` "Keep OG", `level` 2).
public struct OptimizeSettings: Codable {
    public let enabled: Bool
    public let skipTag: String
    public let level: Int

    public init(enabled: Bool, skipTag: String = "Keep OG", level: Int = 2) {
        self.enabled = enabled
        self.skipTag = skipTag
        self.level = level
    }

    private enum CodingKeys: String, CodingKey { case enabled, skipTag, level }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        skipTag = try c.decodeIfPresent(String.self, forKey: .skipTag) ?? "Keep OG"
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 2
    }
}

public enum VerifyResult: Equatable {
    case ok
    case originalUnreadable
    case candidateInvalid
}

/// One format's optimizer: which extensions it owns, which external tool runs
/// it, how to build the tool's arguments, and how to verify a candidate
/// against the original. Everything else in the pipeline is format-neutral —
/// adding PDF later is one more value in a registry, nothing else.
public struct FileOptimizer {
    public let name: String
    public let extensions: Set<String>
    public let toolNames: [String]
    public let arguments: (String, String, Int) -> [String]
    public let verify: (URL, URL) -> VerifyResult

    public init(
        name: String, extensions: Set<String>, toolNames: [String],
        arguments: @escaping (String, String, Int) -> [String],
        verify: @escaping (URL, URL) -> VerifyResult
    ) {
        self.name = name
        self.extensions = extensions
        self.toolNames = toolNames
        self.arguments = arguments
        self.verify = verify
    }
}

/// oxipng suppresses not-smaller output without --force; Sift's own size
/// check is the single arbiter for every tool, so force output always.
public let imageOptimizers: [FileOptimizer] = [
    FileOptimizer(
        name: "png", extensions: ["png"], toolNames: ["oxipng"],
        arguments: { input, output, level in
            ["--out", output, "--force", "-o", String(level), "--strip", "safe", input]
        },
        verify: { verifyImage(original: $0, candidate: $1) }),
    FileOptimizer(
        name: "jpeg", extensions: ["jpg", "jpeg"], toolNames: ["jpegtran"],
        arguments: { input, output, _ in
            ["-copy", "all", "-optimize", "-progressive", "-outfile", output, input]
        },
        verify: { verifyImage(original: $0, candidate: $1) }),
    FileOptimizer(
        name: "gif", extensions: ["gif"], toolNames: ["gifsicle"],
        arguments: { input, output, _ in ["-O2", "-o", output, input] },
        verify: { verifyImage(original: $0, candidate: $1) }),
]

public let imageOptimResourcesDir =
    "/Applications/ImageOptim.app/Contents/Frameworks/ImageOptimGPL.framework/Versions/A/Resources"

public func defaultToolSearchDirs(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return pathDirs + [imageOptimResourcesDir]
}

public func findTool(named name: String, searchDirs: [String]) -> String? {
    for dir in searchDirs {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Full-decode verification: both files must decode completely and agree on
/// pixel dimensions. `statusComplete` matters — ImageIO happily progressive-
/// decodes truncated files, which is exactly the partial-download case.
public func verifyImage(original: URL, candidate: URL) -> VerifyResult {
    guard let o = decodeComplete(original) else { return .originalUnreadable }
    guard let c = decodeComplete(candidate), c.width == o.width, c.height == o.height
    else { return .candidateInvalid }
    return .ok
}

private func decodeComplete(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceGetStatus(src) == .statusComplete
    else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SiftCoreTests.OptimizeTests`
Expected: 12 tests PASS.

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Optimize.swift Tests/SiftCoreTests/OptimizeTests.swift
git commit -m "feat(optimize): settings, optimizer registry, tool discovery, image verify"
```

---

### Task 5: Config wiring — optional `optimize` block

**Files:**
- Modify: `Sources/SiftCore/Config.swift` (`Settings` struct at line ~8, `validate` at line ~73)
- Modify: `Tests/SiftCoreTests/ScannerTests.swift:46-49` (the `Settings(` call gains `optimize: nil`)
- Modify: `sift.example.json`
- Test: `Tests/SiftCoreTests/ConfigTests.swift`, `Tests/SiftCoreTests/ExampleConfigTests.swift`

**Interfaces:**
- Consumes: `OptimizeSettings` (Task 4).
- Produces: `Settings.optimize: OptimizeSettings?`. Validation rejects `level` outside `0...6` and empty `skipTag`. Tasks 6–7 read `config.settings.optimize`.

- [ ] **Step 1: Write the failing tests**

Append to `ConfigTests.swift` (its `valid` fixture is a JSON string; check how
`writeTemp` is used at the top of the file and follow the same pattern):

```swift
    func testConfigWithoutOptimizeBlockDecodesAndValidates() throws {
        // The deployed config predates the optimize feature.
        let config = try loadConfig(at: writeTemp(valid))
        XCTAssertNil(config.settings.optimize)
    }

    func testOptimizeBlockDecodes() throws {
        let withOpt = valid.replacingOccurrences(
            of: "\"tagging\":",
            with: "\"optimize\": { \"enabled\": true, \"skipTag\": \"Keep OG\", \"level\": 2 }, \"tagging\":")
        let config = try loadConfig(at: writeTemp(withOpt))
        let opt = try XCTUnwrap(config.settings.optimize)
        XCTAssertTrue(opt.enabled)
        XCTAssertEqual(opt.level, 2)
    }

    func testOptimizeRejectsBadLevel() throws {
        let bad = valid.replacingOccurrences(
            of: "\"tagging\":",
            with: "\"optimize\": { \"enabled\": true, \"level\": 9 }, \"tagging\":")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }

    func testOptimizeRejectsEmptySkipTag() throws {
        let bad = valid.replacingOccurrences(
            of: "\"tagging\":",
            with: "\"optimize\": { \"enabled\": true, \"skipTag\": \"\" }, \"tagging\":")
        XCTAssertThrowsError(try loadConfig(at: writeTemp(bad)))
    }
```

(If the `valid` fixture's `"tagging":` spelling differs — e.g. spacing — open
`ConfigTests.swift` first and adjust the `replacingOccurrences` anchor to match
the fixture exactly.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.ConfigTests`
Expected: compile FAILURE — `Settings` has no `optimize` member.

- [ ] **Step 3: Implement**

In `Config.swift`, add the field to `Settings`:

```swift
public struct Settings: Codable {
    public let interval: String
    public let log: String
    public let dryRun: Bool
    public let categories: [String: [String]]
    public let tagging: Tagging
    public let optimize: OptimizeSettings?
}
```

In `validate(_:)`, after the interval check:

```swift
    if let opt = c.settings.optimize {
        guard (0...6).contains(opt.level) else {
            throw ConfigError.validation("bad optimize.level: \(opt.level) (0-6)")
        }
        guard !opt.skipTag.isEmpty else {
            throw ConfigError.validation("optimize.skipTag must not be empty")
        }
    }
```

In `ScannerTests.swift` line ~46, the `Settings(` initializer call gains
`optimize: nil` as its final argument:

```swift
        let settings = Settings(
            interval: "1h", log: root.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"], "documents": ["rtfd", "txt", "pdf"]],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
```

In `sift.example.json`, add inside `"settings"`, after the `"tagging"` line:

```json
    "tagging": { "enabled": true, "prefix": "Sift" },
    "optimize": { "enabled": true, "skipTag": "Keep OG", "level": 2 }
```

(Keep the example's existing key order otherwise; `ExampleConfigTests` asserts
the example validates, so run it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: full suite PASS, including `ExampleConfigTests`.

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Config.swift Tests/SiftCoreTests/ConfigTests.swift \
        Tests/SiftCoreTests/ScannerTests.swift sift.example.json
git commit -m "feat(config): optional optimize block with level/skipTag validation"
```

---

### Task 6: `OptimizePass.swift` — the walk and the pipeline

**Files:**
- Create: `Sources/SiftCore/OptimizePass.swift`
- Test: `Tests/SiftCoreTests/OptimizePassTests.swift`

**Interfaces:**
- Consumes: `runProcess` (Task 1); `captureXattrs`/`restoreXattrs`/`addSiftTag`/`rawTags`/`setDateAdded`/`dateAdded` (Task 2 + existing); `isKeepOGTag`/`isOptimizedTag` (Task 3); `FileOptimizer`/`OptimizeSettings`/`findTool`/`defaultToolSearchDirs`/`imageOptimizers` (Task 4); `Settings.optimize` (Task 5); existing `standardizePath`, `CategoryResolver`.
- Produces: `public struct OptimizePass` with
  `public init(config: Config, dryRun: Bool, log: @escaping (String) -> Void, optimizers: [FileOptimizer] = imageOptimizers, toolPaths: [String: String]? = nil, timeout: TimeInterval = 120)`
  and `public func run()`. Task 7 constructs it in `cmdRun`.

- [ ] **Step 1: Write the failing tests**

`Tests/SiftCoreTests/OptimizePassTests.swift`:

```swift
import XCTest

@testable import SiftCore

final class OptimizePassTests: XCTestCase {
    private var home: URL!
    private var toolsDir: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-optpass-\(UUID().uuidString)")
        toolsDir = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private func config(optimize: OptimizeSettings? = OptimizeSettings(enabled: true))
        -> Config
    {
        let desktop = home.appendingPathComponent("Desktop").path
        let review = home.appendingPathComponent("Desktop/Desktop to Review").path
        let delete = home.appendingPathComponent("Desktop/Desktop to Delete").path
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let live = FolderConfig(
            path: desktop, ignore: ["Desktop to Review", "Desktop to Delete"],
            rules: [
                Rule(
                    name: "toReview", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(to: review, sortInto: "category", onConflict: "rename")
                        )
                    ])
            ])
        let reviewFolder = FolderConfig(
            path: review, ignore: nil,
            rules: [
                Rule(
                    name: "toDelete", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(to: delete, sortInto: "category", onConflict: "rename")
                        )
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: home.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"]],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: optimize)
        return Config(settings: settings, folders: [live, reviewFolder])
    }

    /// A stub "optimizer" whose tool is a shell script the test writes.
    private func stubOptimizer(
        verify: @escaping (URL, URL) -> VerifyResult = { _, _ in .ok }
    ) -> FileOptimizer {
        FileOptimizer(
            name: "stub", extensions: ["png"], toolNames: ["stubtool"],
            arguments: { input, output, _ in [input, output] }, verify: verify)
    }

    private func writeTool(_ script: String) throws -> String {
        let url = toolsDir.appendingPathComponent("stubtool-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private let shrinkScript = #"size=$(wc -c < "$1"); head -c $((size / 2)) "$1" > "$2""#
    private let growScript = #"cat "$1" "$1" > "$2""#
    private let failScript = "exit 1"

    private func makePNGFile(_ rel: String, bytes: Int = 4096) throws -> URL {
        // Content doesn't matter for stub-verify tests; size does.
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        try setDateAdded(url.path, to: Date().addingTimeInterval(-3 * 86400))
        return url
    }

    private func runPass(
        tool: String, optimize: OptimizeSettings? = OptimizeSettings(enabled: true),
        verify: @escaping (URL, URL) -> VerifyResult = { _, _ in .ok },
        dryRun: Bool = false, timeout: TimeInterval = 120,
        log: @escaping (String) -> Void = { _ in }
    ) {
        OptimizePass(
            config: config(optimize: optimize), dryRun: dryRun, log: log,
            optimizers: [stubOptimizer(verify: verify)], toolPaths: ["stub": tool],
            timeout: timeout
        ).run()
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    // MARK: - Success path

    func testOptimizesShrinksMarksAndPreservesMetadata() throws {
        let file = try makePNGFile("Desktop/a.png")
        let originalAdded = try XCTUnwrap(dateAdded(of: file.path))
        try setSiftTag(
            file.path, text: "Sift · 5d → Delete", color: 7, prefix: "Sift",
            preserving: { _ in false })
        var logs: [String] = []
        runPass(tool: try writeTool(shrinkScript), log: { logs.append($0) })

        XCTAssertEqual(size(file), 2048)
        let tags = rawTags(of: file.path)
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · Optimized") })
        // Pre-existing tags restored across the replace.
        XCTAssertTrue(tags.contains { $0.hasPrefix("Sift · 5d → Delete") })
        // Date Added restored: aging clock unaffected.
        let added = try XCTUnwrap(dateAdded(of: file.path))
        XCTAssertEqual(
            added.timeIntervalSince1970, originalAdded.timeIntervalSince1970, accuracy: 2)
        XCTAssertTrue(logs.contains { $0.hasPrefix("OPT ") })
    }

    func testMarkedFileIsSkippedWithoutRunningTool() throws {
        let file = try makePNGFile("Desktop/a.png")
        try addSiftTag(file.path, text: "Sift · Optimized", color: 2)
        // A tool that would blow up if invoked.
        runPass(tool: try writeTool(failScript))
        XCTAssertEqual(size(file), 4096)  // untouched
    }

    func testKeepOGSkipsBareAndNamespaced() throws {
        for (idx, tag) in ["Keep OG", "Sift · Keep OG"].enumerated() {
            let file = try makePNGFile("Desktop/og\(idx).png")
            try addSiftTag(file.path, text: tag, color: 3)
            var logs: [String] = []
            runPass(tool: try writeTool(shrinkScript), log: { logs.append($0) })
            XCTAssertEqual(size(file), 4096, tag)  // untouched
            XCTAssertFalse(
                rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") }, tag)
            XCTAssertTrue(logs.contains { $0.hasPrefix("SKIP") }, tag)
        }
    }

    func testCustomSkipTagIsHonored() throws {
        let file = try makePNGFile("Desktop/a.png")
        try addSiftTag(file.path, text: "Original", color: 3)
        runPass(
            tool: try writeTool(shrinkScript),
            optimize: OptimizeSettings(enabled: true, skipTag: "Original"))
        XCTAssertEqual(size(file), 4096)
    }

    // MARK: - Failure paths (original always untouched, no marker)

    func testToolFailureLeavesOriginalUnmarked() throws {
        let file = try makePNGFile("Desktop/a.png")
        var logs: [String] = []
        runPass(tool: try writeTool(failScript), log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
        XCTAssertTrue(logs.contains { $0.hasPrefix("ERROR optimize ") })
    }

    func testTimeoutLeavesOriginalUnmarked() throws {
        let file = try makePNGFile("Desktop/a.png")
        var logs: [String] = []
        runPass(tool: try writeTool("sleep 30"), timeout: 0.5, log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
        XCTAssertTrue(logs.contains { $0.contains("timeout") })
    }

    func testNotSmallerMarksWithoutReplacing() throws {
        let file = try makePNGFile("Desktop/a.png")
        runPass(tool: try writeTool(growScript))
        XCTAssertEqual(size(file), 4096)  // original kept
        XCTAssertTrue(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testUnreadableOriginalSkippedWithoutMarker() throws {
        let file = try makePNGFile("Desktop/a.png")
        runPass(tool: try writeTool(shrinkScript), verify: { _, _ in .originalUnreadable })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
    }

    func testInvalidCandidateLeavesOriginalUnmarked() throws {
        let file = try makePNGFile("Desktop/a.png")
        var logs: [String] = []
        runPass(
            tool: try writeTool(shrinkScript), verify: { _, _ in .candidateInvalid },
            log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
        XCTAssertTrue(logs.contains { $0.hasPrefix("ERROR verify ") })
    }

    func testNoTempFilesLeftBehind() throws {
        _ = try makePNGFile("Desktop/a.png")
        _ = try makePNGFile("Desktop/b.png")
        runPass(tool: try writeTool(failScript))
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: home.appendingPathComponent("Desktop").path
        ).filter { $0.contains(".sift-opt-") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Walk

    func testWalksReviewAndDeleteCategorySubfolders() throws {
        let inReview = try makePNGFile("Desktop/Desktop to Review/Images/a.png")
        let inDelete = try makePNGFile("Desktop/Desktop to Delete/Images/b.png")
        runPass(tool: try writeTool(shrinkScript))
        XCTAssertEqual(size(inReview), 2048)
        XCTAssertEqual(size(inDelete), 2048)
    }

    func testDoesNotEnterUserFolders() throws {
        let nested = try makePNGFile("Desktop/vacation/photo.png")
        runPass(tool: try writeTool(shrinkScript))
        XCTAssertEqual(size(nested), 4096)  // untouched: user folder is opaque
    }

    func testHonorsIgnoreListAndExtensionFilter() throws {
        let txt = try makePNGFile("Desktop/notes.txt")
        let partial = try makePNGFile("Desktop/photo.png.crdownload")
        runPass(tool: try writeTool(shrinkScript))
        XCTAssertEqual(size(txt), 4096)
        XCTAssertEqual(size(partial), 4096)
    }

    // MARK: - Modes

    func testDisabledDoesNothing() throws {
        let file = try makePNGFile("Desktop/a.png")
        runPass(
            tool: try writeTool(shrinkScript),
            optimize: OptimizeSettings(enabled: false))
        XCTAssertEqual(size(file), 4096)
        runPass(tool: try writeTool(shrinkScript), optimize: nil)
        XCTAssertEqual(size(file), 4096)
    }

    func testDryRunLogsButChangesNothing() throws {
        let file = try makePNGFile("Desktop/a.png")
        var logs: [String] = []
        runPass(tool: try writeTool(shrinkScript), dryRun: true, log: { logs.append($0) })
        XCTAssertEqual(size(file), 4096)
        XCTAssertTrue(rawTags(of: file.path).isEmpty)
        XCTAssertTrue(logs.contains { $0.hasPrefix("DRY optimize ") })
    }

    func testMissingToolLogsOnceAndSkips() throws {
        let file = try makePNGFile("Desktop/a.png")
        var logs: [String] = []
        OptimizePass(
            config: config(), dryRun: false, log: { logs.append($0) },
            optimizers: [stubOptimizer()], toolPaths: [:], timeout: 5
        ).run()
        XCTAssertEqual(size(file), 4096)
        XCTAssertFalse(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
        XCTAssertEqual(logs.filter { $0.hasPrefix("SKIP no optimizer") }.count, 1)
    }

    // MARK: - Real tool (integration, skipped when oxipng absent)

    func testRealOxipngRoundTrip() throws {
        let oxipng = findTool(named: "oxipng", searchDirs: defaultToolSearchDirs())
        try XCTSkipIf(oxipng == nil, "oxipng not installed")
        let file = home.appendingPathComponent("Desktop/real.png")
        try OptimizeTests.writePNG(to: file, width: 64, height: 64)
        try setDateAdded(file.path, to: Date().addingTimeInterval(-3 * 86400))
        let before = size(file)
        OptimizePass(
            config: config(), dryRun: false, log: { _ in },
            optimizers: imageOptimizers, toolPaths: ["png": oxipng!], timeout: 120
        ).run()
        // Either it shrank (replaced + marked) or it couldn't (marked anyway).
        XCTAssertLessThanOrEqual(size(file), before)
        XCTAssertTrue(rawTags(of: file.path).contains { $0.hasPrefix("Sift · Optimized") })
        XCTAssertEqual(
            verifyImage(original: file, candidate: file), .ok)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.OptimizePassTests`
Expected: compile FAILURE — `OptimizePass` not defined.

- [ ] **Step 3: Implement**

`Sources/SiftCore/OptimizePass.swift`:

```swift
import Darwin
import Foundation

/// The optimize pass: walks every watched folder plus every move destination
/// and pushes candidate files through a uniform temp-file pipeline. Runs
/// before the aging pass; restores Date Added afterward so aging is blind to
/// it. Per-format behavior lives entirely in the FileOptimizer registry.
public struct OptimizePass {
    let config: Config
    let dryRun: Bool
    let log: (String) -> Void
    let settings: OptimizeSettings
    let resolver: CategoryResolver
    let optimizers: [FileOptimizer]
    let toolPaths: [String: String]
    let timeout: TimeInterval

    public init(
        config: Config, dryRun: Bool, log: @escaping (String) -> Void,
        optimizers: [FileOptimizer] = imageOptimizers,
        toolPaths: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) {
        self.config = config
        self.dryRun = dryRun
        self.log = log
        self.settings = config.settings.optimize ?? OptimizeSettings(enabled: false)
        self.resolver = CategoryResolver(map: config.settings.categories)
        self.optimizers = optimizers
        self.toolPaths = toolPaths ?? Self.resolveTools(optimizers)
        self.timeout = timeout
    }

    static func resolveTools(_ optimizers: [FileOptimizer]) -> [String: String] {
        let dirs = defaultToolSearchDirs()
        var out: [String: String] = [:]
        for optimizer in optimizers {
            for tool in optimizer.toolNames {
                if let path = findTool(named: tool, searchDirs: dirs) {
                    out[optimizer.name] = path
                    break
                }
            }
        }
        return out
    }

    public func run() {
        guard settings.enabled else { return }
        for optimizer in optimizers where toolPaths[optimizer.name] == nil {
            log("SKIP no optimizer for \(optimizer.name)")
        }
        for file in candidates() {
            process(file)
        }
    }

    // MARK: - Walk

    /// Watched folders plus their move destinations, deduplicated. A folder
    /// that is a destination gets the one-level descent into Sift's own
    /// category subfolders (Review AND Delete both have them); user folders
    /// and bundles are opaque, matching the aging pass's invariant.
    private func candidates() -> [URL] {
        var folders: [(url: URL, ignore: Set<String>, descend: Bool)] = []
        var seen = Set<String>()
        let dests = Set(
            config.folders.flatMap { folder in
                folder.rules.flatMap { rule in
                    rule.actions.map { standardizePath($0.move.to) }
                }
            })
        for folder in config.folders {
            let path = standardizePath(folder.path)
            guard seen.insert(path).inserted else { continue }
            folders.append(
                (
                    URL(fileURLWithPath: path), Set(folder.ignore ?? []),
                    dests.contains(path)
                ))
        }
        for dest in dests.sorted() where seen.insert(dest).inserted {
            folders.append((URL(fileURLWithPath: dest), [], true))
        }

        let categoryNames = resolver.categoryFolderNames()
        var out: [URL] = []
        for folder in folders {
            guard
                let top = try? FileManager.default.contentsOfDirectory(
                    at: folder.url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for entry in top {
                if folder.ignore.contains(entry.lastPathComponent) { continue }
                if isDirectory(entry) {
                    guard folder.descend, categoryNames.contains(entry.lastPathComponent),
                        let children = try? FileManager.default.contentsOfDirectory(
                            at: entry, includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles])
                    else { continue }
                    out.append(contentsOf: children.filter { isCandidate($0) })
                } else if isCandidate(entry) {
                    out.append(entry)
                }
            }
        }
        return out
    }

    private func isCandidate(_ url: URL) -> Bool {
        !isDirectory(url) && optimizer(for: url) != nil
    }

    private func optimizer(for url: URL) -> FileOptimizer? {
        let ext = url.pathExtension.lowercased()
        // A partial download ("x.png.crdownload") has extension "crdownload"
        // and matches nothing here — the registry filter is the in-progress
        // guard.
        return optimizers.first { $0.extensions.contains(ext) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: - Pipeline

    private func process(_ file: URL) {
        let prefix = config.settings.tagging.prefix
        let tags = rawTags(of: file.path)
        if tags.contains(where: { isOptimizedTag($0, prefix: prefix) }) { return }
        if tags.contains(where: { isKeepOGTag($0, prefix: prefix, skipTag: settings.skipTag) }) {
            log("SKIP Keep OG \(file.path)")
            return
        }
        guard let optimizer = optimizer(for: file),
            let tool = toolPaths[optimizer.name]
        else { return }
        if dryRun {
            log("DRY optimize \(file.path)")
            return
        }

        let originalSize = size(of: file)
        let added = dateAdded(of: file.path)
        let attrs = captureXattrs(of: file.path)
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".sift-opt-\(UUID().uuidString).\(file.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = runProcess(
            tool, optimizer.arguments(file.path, temp.path, settings.level), timeout: timeout)
        if result.timedOut {
            log("ERROR optimize timeout \(file.path)")
            return
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: temp.path) else {
            log("ERROR optimize \(file.path): tool exited \(result.status)")
            return
        }
        switch optimizer.verify(file, temp) {
        case .originalUnreadable:
            // Likely a file still being written; retry when complete.
            return
        case .candidateInvalid:
            log("ERROR verify \(file.path)")
            return
        case .ok:
            break
        }
        let newSize = size(of: temp)
        guard newSize > 0, newSize < originalSize else {
            mark(file, prefix: prefix)
            log("MARK \(file.path): not smaller")
            return
        }
        guard rename(temp.path, file.path) == 0 else {
            log("ERROR replace \(file.path): errno \(errno)")
            return
        }
        if let added = added {
            do { try setDateAdded(file.path, to: added) } catch {
                log("ERROR stamp \(file.path): \(error)")
            }
        }
        if !restoreXattrs(attrs, to: file.path) {
            log("ERROR xattrs \(file.path)")
        }
        mark(file, prefix: prefix)
        let pct = (originalSize - newSize) * 100 / max(originalSize, 1)
        log("OPT \(file.path): \(originalSize) -> \(newSize) bytes (\(pct)%)")
    }

    private func mark(_ file: URL, prefix: String) {
        do { try addSiftTag(file.path, text: "\(prefix) · Optimized", color: 2) } catch {
            log("ERROR mark \(file.path): \(error)")
        }
    }

    private func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SiftCoreTests.OptimizePassTests`
Expected: 17 tests PASS (the real-oxipng one skips if the tool is absent; the
timeout test takes ~1s).

- [ ] **Step 5: Run the whole suite, format, commit**

```bash
swift test
swift-format format -i -r Sources Tests
git add Sources/SiftCore/OptimizePass.swift Tests/SiftCoreTests/OptimizePassTests.swift
git commit -m "feat(optimize): the optimize pass — walk, pipeline, marker, safety rails"
```

---

### Task 7: CLI + launchd wiring

**Files:**
- Modify: `Sources/SiftCore/CLI.swift:87-94` (`cmdRun`)
- Modify: `Sources/SiftCore/Launchd.swift:11-31` (`makeLaunchdPlist`), `:33-48` (`installAgent`)
- Test: `Tests/SiftCoreTests/LaunchdTests.swift`

**Interfaces:**
- Consumes: `OptimizePass` (Task 6), `Settings.optimize` (Task 5), existing `standardizePath`.
- Produces:
  - `public func watchPaths(for config: Config) -> [String]` — standardized paths of folders that are not move destinations (the live folders).
  - `makeLaunchdPlist(binaryPath:configPath:interval:logPath:watchPaths:)` — gains the parameter; emits `WatchPaths` (when non-empty) and `ThrottleInterval` 30.
  - `cmdRun` runs `OptimizePass` before `Scanner` when `optimize?.enabled == true`.

- [ ] **Step 1: Write the failing tests**

Replace/extend `LaunchdTests.swift`:

```swift
import XCTest

@testable import SiftCore

final class LaunchdTests: XCTestCase {
    func testPlistContents() throws {
        let plist = makeLaunchdPlist(
            binaryPath: "/usr/local/bin/sift",
            configPath: "/Users/x/.config/sift/sift.json",
            interval: 3600,
            logPath: "/Users/x/Library/Logs/sift.log",
            watchPaths: [])
        XCTAssertTrue(plist.contains("<string>com.brandonshutter.sift</string>"))
        XCTAssertTrue(plist.contains("<integer>3600</integer>"))
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/sift</string>"))
        XCTAssertTrue(plist.contains("<string>run</string>"))
        XCTAssertTrue(plist.contains("<key>ThrottleInterval</key>"))
        XCTAssertFalse(plist.contains("<key>WatchPaths</key>"))
        let data = Data(plist.utf8)
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        XCTAssertNotNil(obj as? [String: Any])
    }

    func testPlistIncludesWatchPaths() throws {
        let plist = makeLaunchdPlist(
            binaryPath: "/usr/local/bin/sift",
            configPath: "/Users/x/.config/sift/sift.json",
            interval: 3600,
            logPath: "/Users/x/Library/Logs/sift.log",
            watchPaths: ["/Users/x/Desktop", "/Users/x/Downloads"])
        XCTAssertTrue(plist.contains("<key>WatchPaths</key>"))
        XCTAssertTrue(plist.contains("<string>/Users/x/Desktop</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/x/Downloads</string>"))
    }

    func testWatchPathsAreLiveFoldersOnly() {
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let live = FolderConfig(
            path: "/Users/x/Desktop", ignore: nil,
            rules: [
                Rule(
                    name: "r", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: "/Users/x/Desktop/Desktop to Review",
                                sortInto: "category", onConflict: "rename"))
                    ])
            ])
        let review = FolderConfig(
            path: "/Users/x/Desktop/Desktop to Review", ignore: nil,
            rules: [
                Rule(
                    name: "r2", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: "/Users/x/Desktop/Desktop to Delete",
                                sortInto: "category", onConflict: "rename"))
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: "/tmp/l", dryRun: false, categories: [:],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        let config = Config(settings: settings, folders: [live, review])
        // Review is a destination → excluded; Desktop is live → included.
        XCTAssertEqual(watchPaths(for: config), ["/Users/x/Desktop"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.LaunchdTests`
Expected: compile FAILURE — `makeLaunchdPlist` has no `watchPaths` parameter.

- [ ] **Step 3: Implement Launchd changes**

In `Launchd.swift`:

```swift
/// The folders launchd should watch for immediate runs: configured folders
/// that are not themselves move destinations. Review folders are excluded on
/// purpose — Sift's own moves into them must not re-trigger runs beyond the
/// one fired by the live-folder change itself.
public func watchPaths(for config: Config) -> [String] {
    let dests = Set(
        config.folders.flatMap { folder in
            folder.rules.flatMap { rule in
                rule.actions.map { standardizePath($0.move.to) }
            }
        })
    return config.folders.map { standardizePath($0.path) }.filter { !dests.contains($0) }
}

public func makeLaunchdPlist(
    binaryPath: String, configPath: String,
    interval: TimeInterval, logPath: String,
    watchPaths: [String]
) -> String {
    var dict: [String: Any] = [
        "Label": launchdLabel,
        "ProgramArguments": [binaryPath, "run", "--config", configPath],
        "StartInterval": Int(interval),
        "RunAtLoad": true,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
        "ThrottleInterval": 30,
    ]
    if !watchPaths.isEmpty {
        dict["WatchPaths"] = watchPaths
    }
    guard
        let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0),
        let xml = String(data: data, encoding: .utf8)
    else {
        return ""
    }
    return xml
}
```

In `installAgent`, pass watch paths only when the feature is on:

```swift
    let plist = makeLaunchdPlist(
        binaryPath: binaryPath,
        configPath: expandTilde(configPath),
        interval: interval,
        logPath: expandTilde(config.settings.log),
        watchPaths: config.settings.optimize?.enabled == true ? watchPaths(for: config) : [])
```

- [ ] **Step 4: Wire the pass into `cmdRun`**

In `CLI.swift` `cmdRun`, before the `Scanner` line:

```swift
    if let opt = config.settings.optimize, opt.enabled {
        OptimizePass(config: config, dryRun: dryRun, log: sink).run()
    }
    Scanner(config: config, now: Date(), dryRun: dryRun, log: sink).run()
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: full suite PASS.

- [ ] **Step 6: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/CLI.swift Sources/SiftCore/Launchd.swift \
        Tests/SiftCoreTests/LaunchdTests.swift
git commit -m "feat(cli,launchd): run optimize pass before aging; WatchPaths for immediacy"
```

---

### Task 8: README, final validation

**Files:**
- Modify: `README.md` (new section after "Keeping something"; extend the Config section)

**Interfaces:** none — documentation and verification only.

- [ ] **Step 1: Add the README section**

After the "Keeping something" section, insert:

````markdown
## Optimizing images

With an `optimize` block in the config, Sift losslessly shrinks images
(png/jpg/jpeg/gif) in every folder it watches — including the Review and
Delete stages — before running the aging pass. Pixels are identical; EXIF and
other metadata are preserved; Finder tags and the *Date Added* aging clock
survive optimization.

```json
"optimize": { "enabled": true, "skipTag": "Keep OG", "level": 2 }
```

- Tag a file **`Keep OG`** (or `Sift · Keep OG`) and Sift will never touch its
  bytes. (`Keep OG` only protects the file's contents — it does not stop aging.
  Use `Sift · Keep` for that; the two combine fine.)
- Processed files are tagged **`Sift · Optimized`** (green). Remove the tag to
  make Sift re-optimize a file.
- `level` is the oxipng effort level (0–6, default 2).

Optimizers are external tools found at runtime — `oxipng`, `jpegtran`, and
`gifsicle` from `$PATH` (Homebrew) or from ImageOptim.app's bundled copies.
Missing tools are logged and skipped; nothing breaks.

Installing the agent with optimization enabled adds launchd `WatchPaths` for
the live folders, so a new screenshot or download is optimized within seconds
of landing rather than on the next hourly pass.

**First run:** every existing unoptimized image is processed once. With a
large backlog this single pass can take on the order of an hour of background
CPU; every later pass skips marked files in milliseconds. To do the heavy pass
on your terms, run `sift run` manually once before `sift install`.
````

In the Config field list, add:

```markdown
- `settings.optimize` — optional; `enabled`, `skipTag` (default `Keep OG`),
  and `level` (oxipng 0–6, default 2). Absent = no optimization.
```

- [ ] **Step 2: Full validation**

```bash
swift build
swift test
swift-format lint --strict -r Sources Tests
shellcheck --severity=warning .githooks/* 2>/dev/null || true
```

Expected: build clean, all tests pass, lint exit 0.

- [ ] **Step 3: End-to-end smoke test in the scratchpad**

Build a sandbox config in the session scratchpad (never `~/Desktop`) with a
live folder + Review destination, drop in a real PNG (write one with `sips` or
copy a fixture), a `Keep OG`-tagged PNG, and a pre-marked PNG; run
`.build/debug/sift run --config <sandbox>/sift.json` twice. Verify: first run
logs `OPT` for the plain file only; tags/Date Added preserved; second run logs
nothing for those files. Then `sift status` → only `DRY` lines, no byte changes.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document the optimize pass, Keep OG, and the Optimized marker"
```

Deployment note for the operator (not part of this plan): after merging, the
user runs `/release`. `sift install` must be re-run (the release skill does
this) for the WatchPaths plist change to take effect. The first optimizing run
will grind the ~2,232-file backlog for about an hour.

---

## Self-review notes

- **Spec coverage:** grammar/skip tag → Tasks 3, 6; marker → Tasks 2, 6;
  pipeline + safety table → Task 6; registry/discovery/verify → Task 4; config →
  Task 5; WatchPaths/ThrottleInterval + ordering → Task 7; README/backlog →
  Task 8. The spec's §5 step-1 in-progress-extension guard is implemented
  structurally (registry filter) and tested in
  `testHonorsIgnoreListAndExtensionFilter`.
- **Type consistency:** `runProcess(_:_:timeout:)`, `ShellResult`,
  `captureXattrs/restoreXattrs/addSiftTag`, `isKeepOGTag(_:prefix:skipTag:)`,
  `isOptimizedTag(_:prefix:)`, `isPersistentSiftTag(_:prefix:)`,
  `OptimizeSettings(enabled:skipTag:level:)`, `VerifyResult`, `FileOptimizer`,
  `findTool(named:searchDirs:)`, `defaultToolSearchDirs(environment:)`,
  `OptimizePass(config:dryRun:log:optimizers:toolPaths:timeout:)`,
  `watchPaths(for:)`, `makeLaunchdPlist(...watchPaths:)` — used identically
  everywhere they appear.
- **Known judgment calls encoded here:** marker survives pin retirement
  (Task 3); `candidateInvalid` gets ERROR + retry rather than a marker; the
  in-progress guard is the registry filter; WatchPaths only when optimize is
  enabled.
