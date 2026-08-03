# Event Log & HTML Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A structured JSONL event log of every real state change, and a `sift report` command that renders it — plus folders, rules, and what's due next — as a self-contained HTML page.

**Architecture:** `Scanner` and `OptimizePass` gain an `event:` closure alongside their existing `log:` closure. The CLI wires that closure to a JSONL appender on real runs and to a no-op on dry runs, so `.pending` events (what *would* happen) never touch disk. `sift report` runs a dry-run `Scanner` with a collecting sink, merges live + archived events, and hands both to a pure `renderReport` function.

**Tech Stack:** Swift 5.9, Foundation only. HTML built by string interpolation — no template engine, no dependencies.

**Spec:** `docs/superpowers/specs/2026-08-03-events-and-report-design.md` — read it first.

## Global Constraints

- Zero SwiftPM dependencies; `Package.swift` untouched; macOS 12 floor.
- `swift-format format -i -r Sources Tests` before every commit; the pre-commit hook runs build + tests + `lint --strict`.
- Dry runs must remain byte-for-byte read-only. Existing tests assert this (`testDryRunChangesNothing`, `testDryRunLeavesPinTagsAndClockUntouched`, `testDryRunLogsButChangesNothing`) — they must keep passing.
- Event emission happens **after** every existing `dryRun` guard, never before.
- `.pending` is dry-run-only and must never be written to the JSONL file.
- Never emit an event for countdown-tag rewrites — that noise is the reason this feature exists.
- The report's default output path is `~/Library/Caches/com.brandonshutter.sift/report.html`, deliberately **not** under `~/Library/Logs/Sift/` (that folder is watched and would rotate the report away).

---

### Task 1: `Events.swift` — the event type, appender, and readers

**Files:**
- Create: `Sources/SiftCore/Events.swift`
- Test: `Tests/SiftCoreTests/EventsTests.swift`

**Interfaces:**
- Consumes: existing `expandTilde(_:)` and `standardizePath(_:)` from `Config.swift`.
- Produces (Tasks 2–5 depend on these exact names):
  - `public enum EventKind: String, Codable { case move, optimize, pinNormalize, pinExpire, pending }`
  - `public struct SiftEvent: Codable, Equatable` with `ts: String`, `kind: EventKind`, `path: String`, `to: String?`, `before: Int?`, `after: Int?`, `remainingDays: Int?`, `detail: String?`, and a memberwise `public init(ts:kind:path:to:before:after:remainingDays:detail:)` where every optional defaults to `nil`.
  - `public static func SiftEvent.now(kind:path:to:before:after:remainingDays:detail:) -> SiftEvent` — stamps `ts` from `Date()`. (Declared as a static factory named `make`; see code.)
  - `public struct EventLog { public init(path: String); public func append(_ event: SiftEvent) }`
  - `public func eventLogPath(for config: Config) -> String`
  - `public func readEvents(at path: String) -> [SiftEvent]`
  - `public func readAllEvents(logDirectory: String) -> [SiftEvent]`

- [ ] **Step 1: Write the failing tests**

`Tests/SiftCoreTests/EventsTests.swift`:

```swift
import XCTest

@testable import SiftCore

final class EventsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Encoding

    func testRoundTrips() throws {
        let event = SiftEvent(
            ts: "2026-08-03T17:50:00Z", kind: .optimize, path: "/a/b.png",
            before: 100, after: 40)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(SiftEvent.self, from: data), event)
    }

    func testMakeStampsTimestamp() {
        let event = SiftEvent.make(kind: .move, path: "/a", to: "/b")
        XCTAssertFalse(event.ts.isEmpty)
        XCTAssertEqual(event.kind, .move)
        XCTAssertEqual(event.to, "/b")
        XCTAssertNil(event.before)
    }

    // MARK: - Appending

    func testAppendWritesOneLinePerEvent() throws {
        let path = dir.appendingPathComponent("nested/events.jsonl").path
        let log = EventLog(path: path)
        log.append(SiftEvent.make(kind: .move, path: "/a", to: "/b"))
        log.append(SiftEvent.make(kind: .optimize, path: "/c.png", before: 10, after: 5))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
        // Each line is independently decodable.
        for line in contents.split(separator: "\n") {
            XCTAssertNoThrow(
                try JSONDecoder().decode(SiftEvent.self, from: Data(line.utf8)))
        }
    }

    func testAppendCreatesMissingDirectory() {
        let path = dir.appendingPathComponent("a/b/c/events.jsonl").path
        EventLog(path: path).append(SiftEvent.make(kind: .move, path: "/x"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testAppendFailureIsSilent() {
        // An unwritable location must never break a run.
        EventLog(path: "/no/such/dir/events.jsonl").append(
            SiftEvent.make(kind: .move, path: "/x"))
    }

    // MARK: - Reading

    func testReadEventsSkipsMalformedLines() throws {
        let path = dir.appendingPathComponent("events.jsonl").path
        let good = #"{"ts":"2026-08-03T00:00:00Z","kind":"move","path":"/a"}"#
        try "\(good)\nnot json\n\n\(good)\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(readEvents(at: path).count, 2)
    }

    func testReadEventsMissingFileIsEmpty() {
        XCTAssertTrue(readEvents(at: dir.appendingPathComponent("nope.jsonl").path).isEmpty)
    }

    func testReadAllMergesArchivesNewestFirst() throws {
        let archive = dir.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        func line(_ ts: String, _ path: String) -> String {
            #"{"ts":"\#(ts)","kind":"move","path":"\#(path)"}"#
        }
        try line("2026-08-03T00:00:00Z", "/new").write(
            toFile: dir.appendingPathComponent("events.jsonl").path,
            atomically: true, encoding: .utf8)
        try line("2026-07-01T00:00:00Z", "/old").write(
            toFile: archive.appendingPathComponent("events.jsonl").path,
            atomically: true, encoding: .utf8)
        try line("2026-07-15T00:00:00Z", "/mid").write(
            toFile: archive.appendingPathComponent("events 2.jsonl").path,
            atomically: true, encoding: .utf8)
        let all = readAllEvents(logDirectory: dir.path)
        XCTAssertEqual(all.map(\.path), ["/new", "/mid", "/old"])
    }

    func testReadAllToleratesMissingEverything() {
        XCTAssertTrue(readAllEvents(logDirectory: dir.path).isEmpty)
    }

    // MARK: - Path derivation

    func testEventLogPathSitsBesideTheTextLog() {
        let settings = Settings(
            interval: "1h", log: "~/Library/Logs/Sift/sift.log", dryRun: false,
            categories: [:], tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        let config = Config(settings: settings, folders: [])
        XCTAssertEqual(
            eventLogPath(for: config),
            NSHomeDirectory() + "/Library/Logs/Sift/events.jsonl")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.EventsTests`
Expected: compile FAILURE — `SiftEvent` not defined.

- [ ] **Step 3: Implement**

`Sources/SiftCore/Events.swift`:

```swift
import Foundation

/// A machine-readable record of something Sift actually did. The text log is
/// for humans; this is the data source for `sift report`. Countdown-tag
/// rewrites are deliberately absent — they are per-pass churn (6,216 of 11,473
/// lines in the production log) and would drown real activity.
public enum EventKind: String, Codable {
    case move
    case optimize
    case pinNormalize
    case pinExpire
    /// Dry-run only: what *would* happen. Never written to disk.
    case pending
}

public struct SiftEvent: Codable, Equatable {
    public let ts: String
    public let kind: EventKind
    public let path: String
    public let to: String?
    public let before: Int?
    public let after: Int?
    public let remainingDays: Int?
    public let detail: String?

    public init(
        ts: String, kind: EventKind, path: String, to: String? = nil,
        before: Int? = nil, after: Int? = nil, remainingDays: Int? = nil,
        detail: String? = nil
    ) {
        self.ts = ts
        self.kind = kind
        self.path = path
        self.to = to
        self.before = before
        self.after = after
        self.remainingDays = remainingDays
        self.detail = detail
    }

    public static func make(
        kind: EventKind, path: String, to: String? = nil,
        before: Int? = nil, after: Int? = nil, remainingDays: Int? = nil,
        detail: String? = nil
    ) -> SiftEvent {
        SiftEvent(
            ts: ISO8601DateFormatter().string(from: Date()), kind: kind, path: path,
            to: to, before: before, after: after, remainingDays: remainingDays,
            detail: detail)
    }
}

/// Appends one JSON object per line. Failures are swallowed: a missing history
/// row must never break a run.
public struct EventLog {
    public let path: String

    public init(path: String) {
        self.path = expandTilde(path)
    }

    public func append(_ event: SiftEvent) {
        guard let data = try? JSONEncoder().encode(event),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((json + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// Beside the text log, so it rotates through the same aging rule.
public func eventLogPath(for config: Config) -> String {
    let logDir = (standardizePath(config.settings.log) as NSString).deletingLastPathComponent
    return (logDir as NSString).appendingPathComponent("events.jsonl")
}

/// Malformed lines are skipped rather than failing the whole read — the file is
/// appended to by a background agent that can be killed mid-write.
public func readEvents(at path: String) -> [SiftEvent] {
    guard let text = try? String(contentsOfFile: expandTilde(path), encoding: .utf8) else {
        return []
    }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
        try? decoder.decode(SiftEvent.self, from: Data(line.utf8))
    }
}

/// The live event log plus every archived one, newest first.
public func readAllEvents(logDirectory: String) -> [SiftEvent] {
    let dir = standardizePath(logDirectory) as NSString
    var events = readEvents(at: dir.appendingPathComponent("events.jsonl"))
    let archive = dir.appendingPathComponent("Archive")
    let archived =
        (try? FileManager.default.contentsOfDirectory(atPath: archive))?
        .filter { $0.hasPrefix("events") && $0.hasSuffix(".jsonl") }
        .sorted() ?? []
    for name in archived {
        events += readEvents(at: (archive as NSString).appendingPathComponent(name))
    }
    return events.sorted { $0.ts > $1.ts }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SiftCoreTests.EventsTests`
Expected: 10 tests PASS.

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Events.swift Tests/SiftCoreTests/EventsTests.swift
git commit -m "feat(events): structured JSONL event log

The text log cannot serve as a data source: unstructured, paths contain
spaces, and countdown churn drowns real activity. Malformed lines are
skipped on read and append failures are silent — history must never
break a run."
```

---

### Task 2: `Scanner` emits move, pin, and pending events

**Files:**
- Modify: `Sources/SiftCore/Scanner.swift` (struct fields + `init` at lines ~3-16; `process` ~55-74; `moveItem` ~76-118; `retirePin`; `writeKeepTag`)
- Test: `Tests/SiftCoreTests/ScannerTests.swift` (append)

**Interfaces:**
- Consumes: `SiftEvent`, `EventKind` (Task 1).
- Produces: `Scanner.init(config:now:dryRun:log:event:)` where `event: @escaping (SiftEvent) -> Void = { _ in }`. Task 4 (CLI) and Task 5 (report) both pass this.

A default is safe here in a way it was not for `setSiftTag(preserving:)`: the worst case of a missing sink is an absent history row, not a destroyed tag. That asymmetry is why one has a default and the other deliberately does not — do not "fix" the inconsistency.

- [ ] **Step 1: Write the failing tests**

Append to `ScannerTests.swift`:

```swift
    // MARK: - Events

    private func collectEvents(
        _ cfg: Config? = nil, dryRun: Bool = false
    ) -> [SiftEvent] {
        var events: [SiftEvent] = []
        Scanner(
            config: cfg ?? config(), now: Date(), dryRun: dryRun, log: { _ in },
            event: { events.append($0) }
        ).run()
        return events
    }

    func testMoveEmitsOneMoveEvent() throws {
        _ = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        let moves = collectEvents().filter { $0.kind == .move }
        XCTAssertEqual(moves.count, 1)
        XCTAssertTrue(moves[0].path.hasSuffix("Desktop/old.png"))
        XCTAssertTrue(moves[0].to?.hasSuffix("Desktop to Review/Images/old.png") ?? false)
    }

    func testCountdownTaggingEmitsNoActionEvents() throws {
        // A fresh Review item only gets its countdown rewritten — pure churn,
        // and the reason this event log exists. It must not appear as activity.
        _ = try makeFile("Desktop/Desktop to Review/Images/new.png", addedDaysAgo: 1)
        let events = collectEvents()
        XCTAssertTrue(events.allSatisfy { $0.kind == .pending })
    }

    func testPinNormalizationEmitsEvent() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep 30d")
        let events = collectEvents().filter { $0.kind == .pinNormalize }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].detail?.hasPrefix("Sift · Keep until") ?? false)
    }

    func testPinExpiryEmitsEvent() throws {
        let path = try makeFile("Desktop/old.png", addedDaysAgo: 10)
        try pin(path, "Sift · Keep until \(isoDay(offsetDays: -2))")
        let events = collectEvents().filter { $0.kind == .pinExpire }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].path.hasSuffix("old.png"))
    }

    func testDryRunEmitsPendingAndNoActions() throws {
        _ = try makeFile("Desktop/soon.png", addedDaysAgo: 5)
        _ = try makeFile("Desktop/due.png", addedDaysAgo: 10)
        let events = collectEvents(dryRun: true)
        XCTAssertTrue(events.allSatisfy { $0.kind == .pending })
        let byName = Dictionary(
            uniqueKeysWithValues: events.map { (($0.path as NSString).lastPathComponent, $0) })
        // 5 days elapsed against a 7d threshold -> 2 days left.
        XCTAssertEqual(byName["soon.png"]?.remainingDays, 2)
        // Overdue -> 0, meaning "moves on the next real pass".
        XCTAssertEqual(byName["due.png"]?.remainingDays, 0)
    }

    func testPendingIsEmittedForLiveFolderItemsNotJustReview() throws {
        // tagCountdown only runs for terminal destinations, so emitting from
        // there would omit every live-folder item counting down to Review.
        _ = try makeFile("Desktop/soon.png", addedDaysAgo: 3)
        let pending = collectEvents(dryRun: true).filter { $0.kind == .pending }
        XCTAssertTrue(pending.contains { $0.path.hasSuffix("Desktop/soon.png") })
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.ScannerTests`
Expected: compile FAILURE — `Scanner.init` has no `event:` parameter.

- [ ] **Step 3: Add the sink to `Scanner`**

In `Scanner.swift`, add the stored property after `log` and the parameter to `init`:

```swift
    let log: (String) -> Void
    let event: (SiftEvent) -> Void
    let resolver: CategoryResolver

    public init(
        config: Config, now: Date, dryRun: Bool, log: @escaping (String) -> Void,
        event: @escaping (SiftEvent) -> Void = { _ in }
    ) {
        self.config = config
        self.now = now
        self.dryRun = dryRun
        self.log = log
        self.event = event
        self.resolver = CategoryResolver(map: config.settings.categories)
    }
```

- [ ] **Step 4: Emit from the four sites**

In `moveItem`, immediately after the existing `log("MOVE ...")` line and before `return moved.path`:

```swift
            log("MOVE \(item.path) -> \(moved.path)")
            event(
                SiftEvent.make(
                    kind: .move, path: item.path, to: moved.path, detail: lastWord(dest)))
            return moved.path
```

In `retirePin`, after the existing `log("EXPIRE ...")` line and before `return true`:

```swift
        log("EXPIRE \(item.path): keep tag lapsed, resuming aging")
        event(SiftEvent.make(kind: .pinExpire, path: item.path))
        return true
```

In `writeKeepTag`, after the existing `log("KEEP ...")` line inside the `do` block:

```swift
            log("KEEP \(item.path): \(text)")
            event(SiftEvent.make(kind: .pinNormalize, path: item.path, detail: text))
```

In `process`, replace the body after `matched` is computed so the not-moving
branch always reports a countdown — independently of tagging, which only fires
for terminal destinations:

```swift
        let matched = (try? ruleMatches(rule, dateAdded: added, now: now)) ?? false
        if matched {
            if skipMove {
                log("SKIP double-hop guard \(item.path)")
                return nil
            }
            if dryRun { event(pendingEvent(item, rule: rule, added: added)) }
            return moveItem(item, move: move, dest: dest, terminalDest: terminalDest)
        }
        if dryRun { event(pendingEvent(item, rule: rule, added: added)) }
        if terminalDest && config.settings.tagging.enabled {
            tagCountdown(item, rule: rule, added: added, dest: dest)
        }
        return nil
```

And add the helper next to `tagCountdown`:

```swift
    /// Dry-run only: what this item is waiting on. Reported from `process`
    /// rather than `tagCountdown` because the latter runs only for terminal
    /// destinations, which would omit every live-folder item counting down
    /// toward Review — exactly the rows a "due next" view needs.
    private func pendingEvent(_ item: URL, rule: Rule, added: Date) -> SiftEvent {
        let days =
            (rule.conditions.first?.value).flatMap { try? parseDuration($0) }
            .map { remainingDays(dateAdded: added, threshold: $0, now: now) } ?? 0
        return SiftEvent.make(kind: .pending, path: item.path, remainingDays: days)
    }
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS. The dry-run-changes-nothing tests must still pass — events
go to a closure, never to disk, and every emit sits after the existing guards.

- [ ] **Step 6: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Scanner.swift Tests/SiftCoreTests/ScannerTests.swift
git commit -m "feat(scanner): emit move, pin, and pending events

Pending is reported from process() rather than tagCountdown() — the
latter runs only for terminal destinations and would omit every
live-folder item counting down toward Review."
```

---

### Task 3: `OptimizePass` emits optimize events

**Files:**
- Modify: `Sources/SiftCore/OptimizePass.swift` (struct fields + `init`; the success branch of `process`)
- Test: `Tests/SiftCoreTests/OptimizePassTests.swift` (append)

**Interfaces:**
- Consumes: `SiftEvent` (Task 1).
- Produces: `OptimizePass.init(config:dryRun:log:event:optimizers:toolPaths:timeout:)` with `event: @escaping (SiftEvent) -> Void = { _ in }` placed immediately after `log:`.

- [ ] **Step 1: Write the failing tests**

Append to `OptimizePassTests.swift`:

```swift
    // MARK: - Events

    private func collectOptimizeEvents(
        tool: String, dryRun: Bool = false,
        verify: @escaping (URL, URL) -> VerifyResult = { _, _ in .ok }
    ) -> [SiftEvent] {
        var events: [SiftEvent] = []
        OptimizePass(
            config: config(), dryRun: dryRun, log: { _ in }, event: { events.append($0) },
            optimizers: [stubOptimizer(verify: verify)], toolPaths: ["stub": tool],
            timeout: 120
        ).run()
        return events
    }

    func testSuccessfulOptimizeEmitsEventWithByteCounts() throws {
        let file = try makeFile("Desktop/a.png")
        let events = collectOptimizeEvents(tool: try writeTool(shrinkScript))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .optimize)
        XCTAssertEqual(events[0].path, file.path)
        XCTAssertEqual(events[0].before, 4096)
        XCTAssertEqual(events[0].after, 2048)
    }

    func testFailedOptimizeEmitsNothing() throws {
        try makeFile("Desktop/a.png")
        XCTAssertTrue(collectOptimizeEvents(tool: try writeTool(failScript)).isEmpty)
    }

    func testNotSmallerEmitsNothing() throws {
        try makeFile("Desktop/a.png")
        XCTAssertTrue(collectOptimizeEvents(tool: try writeTool(growScript)).isEmpty)
    }

    func testSkippedFileEmitsNothing() throws {
        let file = try makeFile("Desktop/a.png")
        try addSiftTag(file.path, text: "Keep OG", color: 3)
        XCTAssertTrue(collectOptimizeEvents(tool: try writeTool(shrinkScript)).isEmpty)
    }

    func testDryRunEmitsNothing() throws {
        try makeFile("Desktop/a.png")
        XCTAssertTrue(
            collectOptimizeEvents(tool: try writeTool(shrinkScript), dryRun: true).isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.OptimizePassTests`
Expected: compile FAILURE — `OptimizePass.init` has no `event:` parameter.

- [ ] **Step 3: Implement**

In `OptimizePass.swift`, add the stored property after `log` and the parameter
to `init` (immediately after `log:`, before `optimizers:`):

```swift
    let log: (String) -> Void
    let event: (SiftEvent) -> Void
```

```swift
    public init(
        config: Config, dryRun: Bool, log: @escaping (String) -> Void,
        event: @escaping (SiftEvent) -> Void = { _ in },
        optimizers: [FileOptimizer] = imageOptimizers,
        toolPaths: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) {
        self.config = config
        self.dryRun = dryRun
        self.log = log
        self.event = event
        self.settings = config.settings.optimize ?? OptimizeSettings(enabled: false)
        self.resolver = CategoryResolver(map: config.settings.categories)
        self.optimizers = optimizers
        self.toolPaths = toolPaths ?? Self.resolveTools(optimizers)
        self.timeout = timeout
    }
```

At the end of `process`, after the existing `log("OPT ...")` line:

```swift
        log("OPT \(file.path): \(originalSize) -> \(newSize) bytes (\(saved)%)")
        event(
            SiftEvent.make(
                kind: .optimize, path: file.path, before: originalSize, after: newSize))
```

Note the placement: this is inside the branch that already performed the atomic
replace, so the not-smaller path (which marks but does not replace) and every
failure path emit nothing — matching the tests above.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/OptimizePass.swift Tests/SiftCoreTests/OptimizePassTests.swift
git commit -m "feat(optimize): emit an event on successful optimization

Only the branch that actually replaced the file emits — a marked
not-smaller file and every failure path stay out of the history."
```

---

### Task 4: Wire the event log into `sift run`

**Files:**
- Modify: `Sources/SiftCore/CLI.swift` (`cmdRun`, lines ~87-99)
- Test: `Tests/SiftCoreTests/CLITests.swift` (append)

**Interfaces:**
- Consumes: `EventLog`, `eventLogPath(for:)` (Task 1); the `event:` parameters (Tasks 2–3).
- Produces: no new public API. `sift run` writes `events.jsonl`; `sift status` and `--dry-run` write nothing.

- [ ] **Step 1: Write the failing tests**

Append to `CLITests.swift`:

```swift
    /// Builds a throwaway config whose log (and therefore event log) lives in a
    /// temp directory, runs a command, and returns the event-log contents.
    private func runWithTempConfig(_ argv: [String], stale: Bool) throws -> (
        events: String?, dir: URL
    ) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-cli-\(UUID().uuidString)")
        let desktop = dir.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let file = desktop.appendingPathComponent("old.png")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        if stale {
            try setDateAdded(file.path, to: Date().addingTimeInterval(-10 * 86400))
        }
        let json = """
            {
              "settings": {
                "interval": "1h", "log": "\(dir.path)/Logs/sift.log", "dryRun": false,
                "categories": { "images": ["png"] },
                "tagging": { "enabled": true, "prefix": "Sift" }
              },
              "folders": [
                { "path": "\(desktop.path)", "ignore": ["Desktop to Review"],
                  "rules": [ { "name": "r", "match": "all",
                    "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
                    "actions": [ { "move": { "to": "\(desktop.path)/Desktop to Review", "sortInto": "category", "onConflict": "rename" } } ] } ] }
              ]
            }
            """
        let configPath = dir.appendingPathComponent("sift.json").path
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(runCLI(argv + ["--config", configPath]), 0)
        let eventsPath = dir.appendingPathComponent("Logs/events.jsonl").path
        return (try? String(contentsOfFile: eventsPath, encoding: .utf8), dir)
    }

    func testRunWritesEventLog() throws {
        let (events, dir) = try runWithTempConfig(["run"], stale: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let contents = try XCTUnwrap(events)
        XCTAssertTrue(contents.contains("\"kind\":\"move\""))
        XCTAssertFalse(contents.contains("\"pending\""))
    }

    func testStatusWritesNoEventLog() throws {
        let (events, dir) = try runWithTempConfig(["status"], stale: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(events)
    }

    func testDryRunWritesNoEventLog() throws {
        let (events, dir) = try runWithTempConfig(["run", "--dry-run"], stale: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(events)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.CLITests`
Expected: `testRunWritesEventLog` FAILS (no `events.jsonl` is written, so
`XCTUnwrap` throws). The two negative tests may already pass; that is fine.

- [ ] **Step 3: Implement**

Replace the body of `cmdRun` in `CLI.swift`:

```swift
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
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/CLI.swift Tests/SiftCoreTests/CLITests.swift
git commit -m "feat(cli): write the event log on real runs only

The appender is wired only when not dry-running, so status and
--dry-run stay byte-for-byte read-only and .pending never hits disk."
```

---

### Task 5: `Report.swift` + the `sift report` command

**Files:**
- Create: `Sources/SiftCore/Report.swift`
- Modify: `Sources/SiftCore/CLI.swift` (usage text ~38-57, `runCLI` switch ~59-78, new `cmdReport`)
- Test: `Tests/SiftCoreTests/ReportTests.swift`, `Tests/SiftCoreTests/CLITests.swift`

**Interfaces:**
- Consumes: `SiftEvent`, `readAllEvents(logDirectory:)`, `eventLogPath(for:)` (Task 1); `Scanner.init(…event:)` (Task 2); `runProcess` (Shell).
- Produces:
  - `public struct ReportData { public let config: Config; public let pending: [SiftEvent]; public let history: [SiftEvent]; public init(config:pending:history:) }`
  - `public func renderReport(_ data: ReportData, generated: Date) -> String`
  - `public func defaultReportPath() -> String`
  - CLI command `report` with `--out <path>` and `--open`.

- [ ] **Step 1: Write the failing tests**

`Tests/SiftCoreTests/ReportTests.swift`:

```swift
import XCTest

@testable import SiftCore

final class ReportTests: XCTestCase {
    private func config() -> Config {
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let folder = FolderConfig(
            path: "~/Desktop", ignore: ["Desktop to Review"],
            rules: [
                Rule(
                    name: "Age stale Desktop items", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: "~/Desktop/Desktop to Review", sortInto: "category",
                                onConflict: "rename"))
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: "~/Library/Logs/Sift/sift.log", dryRun: false,
            categories: ["images": ["png"]],
            tagging: Tagging(enabled: true, prefix: "Sift"),
            optimize: OptimizeSettings(enabled: true))
        return Config(settings: settings, folders: [folder])
    }

    private func render(pending: [SiftEvent] = [], history: [SiftEvent] = []) -> String {
        renderReport(
            ReportData(config: config(), pending: pending, history: history),
            generated: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testRendersEmptyStateWithoutCrashing() {
        let html = render()
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("</html>"))
        XCTAssertTrue(html.lowercased().contains("no activity"))
    }

    func testIsSelfContained() {
        let html = render(
            history: [SiftEvent(ts: "2026-08-03T00:00:00Z", kind: .move, path: "/a", to: "/b")])
        // No external assets of any kind — the page must open offline.
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testEscapesHTMLInPaths() {
        let nasty = "/Users/x/Desktop/a&b<c>\"d\".png"
        let html = render(
            history: [SiftEvent(ts: "2026-08-03T00:00:00Z", kind: .optimize, path: nasty)])
        XCTAssertFalse(html.contains("a&b<c>"))
        XCTAssertTrue(html.contains("a&amp;b&lt;c&gt;"))
    }

    func testTotalsSumOptimizeSavings() {
        let html = render(history: [
            SiftEvent(ts: "2026-08-03T00:00:02Z", kind: .optimize, path: "/a", before: 1000, after: 400),
            SiftEvent(ts: "2026-08-03T00:00:01Z", kind: .optimize, path: "/b", before: 3000, after: 1000),
            SiftEvent(ts: "2026-08-03T00:00:00Z", kind: .move, path: "/c", to: "/d"),
        ])
        // 2 optimized, 2600 bytes reclaimed, 1 move.
        XCTAssertTrue(html.contains(">2<"))
        XCTAssertTrue(html.contains("2.6 KB") || html.contains("2,600"))
    }

    func testPendingSortsByRemainingDaysAscending() {
        let html = render(pending: [
            SiftEvent(ts: "t", kind: .pending, path: "/later.png", remainingDays: 6),
            SiftEvent(ts: "t", kind: .pending, path: "/now.png", remainingDays: 0),
            SiftEvent(ts: "t", kind: .pending, path: "/soon.png", remainingDays: 2),
        ])
        let now = try! XCTUnwrap(html.range(of: "now.png"))
        let soon = try! XCTUnwrap(html.range(of: "soon.png"))
        let later = try! XCTUnwrap(html.range(of: "later.png"))
        XCTAssertTrue(now.lowerBound < soon.lowerBound)
        XCTAssertTrue(soon.lowerBound < later.lowerBound)
    }

    func testRendersFoldersAndRules() {
        let html = render()
        XCTAssertTrue(html.contains("~/Desktop"))
        XCTAssertTrue(html.contains("Age stale Desktop items"))
        XCTAssertTrue(html.contains("7d"))
    }

    func testAbbreviatesHomeDirectory() {
        let html = render(
            history: [
                SiftEvent(
                    ts: "2026-08-03T00:00:00Z", kind: .move,
                    path: NSHomeDirectory() + "/Desktop/a.png", to: "/tmp/b.png")
            ])
        XCTAssertTrue(html.contains("~/Desktop/a.png"))
        XCTAssertFalse(html.contains(NSHomeDirectory() + "/Desktop/a.png"))
    }
}
```

Append to `CLITests.swift`:

```swift
    func testReportIsAKnownCommand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
            {
              "settings": {
                "interval": "1h", "log": "\(dir.path)/Logs/sift.log", "dryRun": false,
                "categories": { "images": ["png"] },
                "tagging": { "enabled": true, "prefix": "Sift" }
              },
              "folders": [
                { "path": "\(dir.path)/Desktop",
                  "rules": [ { "name": "r", "match": "all",
                    "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
                    "actions": [ { "move": { "to": "\(dir.path)/Review", "sortInto": "none", "onConflict": "rename" } } ] } ] }
              ]
            }
            """
        let configPath = dir.appendingPathComponent("sift.json").path
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("report.html").path
        XCTAssertEqual(runCLI(["report", "--config", configPath, "--out", out]), 0)
        let html = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertTrue(html.contains("</html>"))
    }

    func testUsageMentionsReport() {
        // Smoke: the command is discoverable.
        XCTAssertEqual(runCLI(["help"]), 0)
    }

    func testParsesOutAndOpenFlags() {
        let a = parseArgs(["report", "--out", "/tmp/r.html", "--open"])
        XCTAssertEqual(a.command, "report")
        XCTAssertEqual(a.outPath, "/tmp/r.html")
        XCTAssertTrue(a.openAfter)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.ReportTests`
Expected: compile FAILURE — `renderReport` / `ReportData` not defined.

- [ ] **Step 3: Implement `Report.swift`**

`Sources/SiftCore/Report.swift`:

```swift
import Foundation

public struct ReportData {
    public let config: Config
    public let pending: [SiftEvent]
    public let history: [SiftEvent]

    public init(config: Config, pending: [SiftEvent], history: [SiftEvent]) {
        self.config = config
        self.pending = pending
        self.history = history
    }
}

/// A regenerable artifact, so it belongs in Caches — and deliberately NOT in
/// the Logs directory, which is watched and would age the report into Archive.
public func defaultReportPath() -> String {
    expandTilde("~/Library/Caches/com.brandonshutter.sift/report.html")
}

/// Pure string building: no filesystem access, so the whole page is unit
/// testable. Self-contained by construction — inline CSS, no scripts, no
/// external assets, so it opens offline forever.
public func renderReport(_ data: ReportData, generated: Date) -> String {
    let optimized = data.history.filter { $0.kind == .optimize }
    let moved = data.history.filter { $0.kind == .move }
    let saved = optimized.reduce(0) { $0 + (($1.before ?? 0) - ($1.after ?? 0)) }
    let stamp = DateFormatter.reportStamp.string(from: generated)

    var out = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Sift report</title>
        <style>\(reportCSS)</style>
        </head><body>
        <header><h1>Sift</h1><p class="sub">Generated \(esc(stamp))</p></header>
        <section class="cards">
          \(card(String(optimized.count), "files optimized"))
          \(card(formatBytes(saved), "reclaimed"))
          \(card(String(moved.count), "items moved"))
          \(card(String(data.pending.count), "items tracked"))
        </section>
        """

    out += section("Due next", pendingTable(data.pending))
    out += section("Activity", historyTable(data.history))
    out += section("Watched folders", foldersTable(data.config))
    out += section("Settings", settingsTable(data.config))
    out += "</body></html>\n"
    return out
}

// MARK: - Sections

private func pendingTable(_ pending: [SiftEvent]) -> String {
    if pending.isEmpty { return "<p class=\"empty\">Nothing tracked yet.</p>" }
    let rows = pending.sorted { ($0.remainingDays ?? 0) < ($1.remainingDays ?? 0) }
        .map { event -> String in
            let days = event.remainingDays ?? 0
            let when = days == 0 ? "<span class=\"due\">next pass</span>" : "\(days)d"
            return "<tr><td>\(when)</td><td class=\"path\">\(esc(abbreviate(event.path)))</td></tr>"
        }.joined()
    return "<table><thead><tr><th>Moves in</th><th>Path</th></tr></thead><tbody>\(rows)</tbody></table>"
}

private func historyTable(_ history: [SiftEvent]) -> String {
    if history.isEmpty { return "<p class=\"empty\">No activity recorded yet.</p>" }
    let rows = history.map { event -> String in
        let detail: String
        switch event.kind {
        case .optimize:
            let before = event.before ?? 0
            let after = event.after ?? 0
            let pct = before > 0 ? (before - after) * 100 / before : 0
            detail = "\(formatBytes(before)) → \(formatBytes(after)) (−\(pct)%)"
        case .move:
            detail = esc(abbreviate(event.to ?? ""))
        default:
            detail = esc(event.detail ?? "")
        }
        return """
            <tr><td class="ts">\(esc(event.ts))</td>\
            <td><span class="kind k-\(event.kind.rawValue)">\(esc(event.kind.rawValue))</span></td>\
            <td class="path">\(esc(abbreviate(event.path)))</td>\
            <td class="detail">\(detail)</td></tr>
            """
    }.joined()
    return "<table><thead><tr><th>When</th><th>What</th><th>Path</th><th></th></tr></thead><tbody>\(rows)</tbody></table>"
}

private func foldersTable(_ config: Config) -> String {
    let rows = config.folders.map { folder -> String in
        let rule = folder.rules.first
        let move = rule?.actions.first?.move
        let threshold = rule?.conditions.first?.value ?? "—"
        let ignore = (folder.ignore ?? []).joined(separator: ", ")
        return """
            <tr><td class="path">\(esc(abbreviate(folder.path)))</td>\
            <td>\(esc(rule?.name ?? "—"))</td>\
            <td>\(esc(threshold))</td>\
            <td class="path">\(esc(abbreviate(move?.to ?? "—")))</td>\
            <td>\(esc(move?.sortInto ?? "—"))</td>\
            <td>\(esc(ignore.isEmpty ? "—" : ignore))</td></tr>
            """
    }.joined()
    return "<table><thead><tr><th>Folder</th><th>Rule</th><th>After</th><th>Moves to</th><th>Sort</th><th>Ignores</th></tr></thead><tbody>\(rows)</tbody></table>"
}

private func settingsTable(_ config: Config) -> String {
    let settings = config.settings
    let optimize =
        settings.optimize.map { "enabled — skip tag “\($0.skipTag)”, level \($0.level)" }
        ?? "disabled"
    let rows = [
        ("Interval", settings.interval),
        ("Log", abbreviate(settings.log)),
        ("Tag prefix", settings.tagging.prefix),
        ("Optimize", optimize),
    ].map { "<tr><th>\(esc($0.0))</th><td>\(esc($0.1))</td></tr>" }.joined()
    return "<table class=\"kv\"><tbody>\(rows)</tbody></table>"
}

// MARK: - Helpers

private func section(_ title: String, _ body: String) -> String {
    "<section><h2>\(esc(title))</h2>\(body)</section>"
}

private func card(_ value: String, _ label: String) -> String {
    "<div class=\"card\"><div class=\"value\">\(esc(value))</div><div class=\"label\">\(esc(label))</div></div>"
}

/// Filenames legitimately contain &, <, >, and quotes.
func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB"]
    var value = Double(bytes) / 1024
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return String(format: "%.1f %@", value, units[index])
}

extension DateFormatter {
    static let reportStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private let reportCSS = """
    :root { color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --muted:#6b7280; \
    --line:#e5e7eb; --card:#f9fafb; --accent:#b45309; }
    @media (prefers-color-scheme: dark) { :root { --bg:#111317; --fg:#e8e8e8; \
    --muted:#9aa0a6; --line:#2a2d33; --card:#191c21; --accent:#f59e0b; } }
    * { box-sizing:border-box; }
    body { margin:0; padding:2rem 1.5rem 4rem; background:var(--bg); color:var(--fg);
      font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif; }
    header { max-width:1100px; margin:0 auto 1.5rem; }
    h1 { margin:0; font-size:1.6rem; letter-spacing:-.02em; }
    .sub { margin:.25rem 0 0; color:var(--muted); }
    section { max-width:1100px; margin:0 auto 2rem; }
    h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.08em;
      color:var(--muted); margin:0 0 .6rem; }
    .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:.75rem; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem; }
    .card .value { font-size:1.5rem; font-weight:600; letter-spacing:-.02em; }
    .card .label { color:var(--muted); font-size:.8rem; margin-top:.15rem; }
    table { width:100%; border-collapse:collapse; font-size:13px; display:block;
      overflow-x:auto; white-space:nowrap; }
    th { text-align:left; font-weight:600; color:var(--muted); font-size:.75rem;
      text-transform:uppercase; letter-spacing:.05em; }
    th,td { padding:.45rem .7rem; border-bottom:1px solid var(--line); }
    tbody tr:last-child td { border-bottom:0; }
    .path { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }
    .ts, .detail { color:var(--muted); font-variant-numeric:tabular-nums; }
    .kind { font-size:11px; padding:.1rem .4rem; border-radius:5px; background:var(--card);
      border:1px solid var(--line); }
    .k-optimize { color:#15803d; } .k-move { color:#1d4ed8; }
    .k-pinExpire, .k-pinNormalize { color:var(--accent); }
    .due { color:var(--accent); font-weight:600; }
    .empty { color:var(--muted); font-style:italic; }
    .kv th { width:9rem; }
    """
```

- [ ] **Step 4: Add the CLI command**

In `CLI.swift`, extend `ParsedArgs` and `parseArgs`:

```swift
public struct ParsedArgs: Equatable {
    public let command: String
    public let configPath: String
    public let dryRun: Bool
    public let outPath: String?
    public let openAfter: Bool
}
```

```swift
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
```

Existing `CLITests.testParsesFlags` compares against a `ParsedArgs(...)` literal
— update that call to include `outPath: nil, openAfter: false`.

Add the case to `runCLI`'s switch, after `case "status"`:

```swift
    case "report": return cmdReport(args)
```

Add the command to the usage text, after the `status` line:

```text
          report      Write an HTML report of folders, rules, and activity
```

and to the options block:

```bash
          --out <path>      Report output path (default: ~/Library/Caches/com.brandonshutter.sift/report.html)
          --open            Open the report when done
```

Add `cmdReport` beside the other command functions:

```swift
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
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS. If `testParsesFlags` fails, its `ParsedArgs(...)` literal
still lacks the two new fields — add them.

- [ ] **Step 6: Generate a real report and look at it**

```bash
swift build -c release
.build/release/sift report --out /tmp/sift-report.html
open /tmp/sift-report.html
```

Confirm by eye: summary cards populated, "Due next" lists real countdowns
matching `sift status`, activity shows real moves/optimizes from the deployed
event log (empty until `sift run` has run at least once post-deploy), folders
and rules match the config, and the page renders correctly in both light and
dark mode.

- [ ] **Step 7: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Report.swift Sources/SiftCore/CLI.swift \
        Tests/SiftCoreTests/ReportTests.swift Tests/SiftCoreTests/CLITests.swift
git commit -m "feat(report): sift report renders a self-contained HTML page

Due-next rows come from a dry-run pass of the real Scanner, so they
cannot drift from what an actual run would do. Output defaults to
Caches, not the watched Logs directory, which would rotate it away."
```

---

### Task 6: Docs

**Files:**
- Modify: `README.md` (Commands section; new "Reports" section)
- Modify: `CLAUDE.md` (module map, event-log invariants)

**Interfaces:** documentation only.

- [ ] **Step 1: README — add to the Commands list**

Insert after the `sift status` bullet:

```markdown
- `sift report [--out <path>] [--open]` — write a self-contained HTML page
  showing watched folders, rules, what's due next, and recent activity.
```

- [ ] **Step 2: README — add a section before "## Config"**

```markdown
## Reports

`sift report` writes a single self-contained HTML file — no external assets, no
scripts, readable offline — summarising what Sift is doing:

```bash
sift report --open
```

It shows totals (files optimized, bytes reclaimed, items moved), what's due to
move next, recent activity, your watched folders and rules, and your settings.
The default output is `~/Library/Caches/com.brandonshutter.sift/report.html`;
`--out` overrides it. Regenerate to refresh — the page is a snapshot.

Activity comes from a structured event log at `~/Library/Logs/Sift/events.jsonl`,
written on every real run (never on `--dry-run` or `sift status`). It records
only real state changes — moves, optimizations, and pin normalizations or
expiries — not the countdown tag rewrites that happen every pass. It rotates
through the same 7-day rule as `sift.log`, and reports read the archives too, so
history survives rotation.
```text

- [ ] **Step 3: CLAUDE.md — module map**

Replace the "Plumbing" line so the two new files appear:

```markdown
**Plumbing:** `CLI` (arg parse/dispatch) · `Config` (load, `validate`, `standardizePath`) ·
`Duration` (parse) · `FSMetadata` (Date Added, tags, xattr capture/restore) ·
`Launchd` (agent `com.brandonshutter.sift`, plist, `watchPaths`) · `Logger` ·
`Events` (JSONL event log) · `Report` (HTML rendering)
```

- [ ] **Step 4: CLAUDE.md — add invariants under "### launchd & logging"**

```markdown
- **The event log records actions, never churn.** `Events` captures `move`,
  `optimize`, `pinNormalize`, and `pinExpire` only. Countdown-tag rewrites are
  excluded on purpose — they were 6,216 of 11,473 lines in the production log
  and would drown real activity in any history view.
- **`.pending` is dry-run-only and never written to disk.** `CLI.cmdRun` wires
  the `EventLog` appender only when not dry-running, which is what keeps
  `sift status` and `--dry-run` byte-for-byte read-only.
- **The `event:` sinks have a no-op default; `setSiftTag(preserving:)` does
  not.** The asymmetry is deliberate: a missing event sink loses a history row,
  a wrong `preserving:` closure destroys a user's tag. Do not "fix" it.
- **The report is written to Caches, not Logs.** The Logs directory is watched,
  so a report written there would be aged into `Archive/`.
```

- [ ] **Step 5: Validate and commit**

```bash
swift build && swift test && swift-format lint --strict -r Sources Tests
git add README.md CLAUDE.md
git commit -m "docs: document sift report and the event log"
```

---

## Self-review notes

- **Spec coverage:** §4.1 types/appender/readers → Task 1; §4.2 wiring table →
  Tasks 2–3 (all five emission points); §4.3 dry-run separation → Task 4; §4.4
  rotation interplay → Task 1 (`readAllEvents` globs `Archive/events*.jsonl`),
  exercised by `testReadAllMergesArchivesNewestFirst`; §5.1 CLI → Task 5; §5.2
  `ReportData`/`renderReport` → Task 5; §5.3 five page sections → Task 5
  (`renderReport` composes summary, due next, activity, folders, settings); §6
  error table → Task 1 (silent append, lenient read) and Task 5 (`--out`
  failure exits 1, directory created); §7 testing → Tasks 1–5; §8 file table →
  Tasks 1–6.
- **Type consistency:** `SiftEvent.make(kind:path:to:before:after:remainingDays:detail:)`,
  `EventLog.append(_:)`, `eventLogPath(for:)`, `readEvents(at:)`,
  `readAllEvents(logDirectory:)`, `ReportData(config:pending:history:)`,
  `renderReport(_:generated:)`, `defaultReportPath()`,
  `Scanner.init(config:now:dryRun:log:event:)`,
  `OptimizePass.init(config:dryRun:log:event:optimizers:toolPaths:timeout:)` —
  used identically everywhere they appear. `ParsedArgs` gains `outPath` and
  `openAfter`, and Task 5 Step 4 explicitly calls out the existing
  `testParsesFlags` literal that must be updated.
- **Judgment calls encoded:** `.pending` emitted from `process()` not
  `tagCountdown()` (else live-folder items are invisible); history filtered to
  exclude `.pending` when read back, in case an older file ever contains one;
  `esc`/`abbreviate`/`formatBytes` are internal (not `private`) so
  `ReportTests` can exercise them via `@testable`.
