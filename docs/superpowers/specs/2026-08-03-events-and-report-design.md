# Sift — Event Log & HTML Report Design Spec

**Date:** 2026-08-03
**Status:** Approved for planning

## 1. Overview

Two pieces, built in order:

1. **Structured event log** — a JSONL record of every real state change, written
   alongside the existing human-readable log. This is the missing data source; the
   text log cannot serve as one (unstructured, paths contain spaces, and 6,216 of
   11,473 lines were countdown-tag churn).
2. **`sift report`** — a self-contained HTML page showing watched folders, rules,
   what is due next, activity history, and totals.

The event sink is a closure, so the same traversal that performs actions also
reports intended ones during a dry run. "What's due next" in the report is
therefore produced by the real `Scanner`, not a reimplementation of its rules.

## 2. Goals

- Record `move`, `optimize`, `pinNormalize`, and `pinExpire` as machine-readable
  events. Never record countdown-tag rewrites — that is the noise this replaces.
- Emit nothing during a dry run *to disk*; a dry run instead reports `pending`
  events to whatever sink the caller supplies.
- Rotate the event log through the same 7-day rule as `sift.log`, and have the
  report read the live file plus its archives so history survives rotation.
- Produce a single HTML file with no external assets, readable offline, in a
  location that is not itself subject to rotation.
- Leave the existing text log and every current invariant untouched.

## 3. Non-Goals

- No filtering, search, or pagination in the report (v1 data is small).
- No live refresh — regenerate to update.
- No automatic report generation on every run.
- No app bundle, menu bar item, or Xcode project. `Package.swift` is unchanged.
- No new SwiftPM dependencies; HTML is assembled by string building.

## 4. Part 1 — the event log

### 4.1 New: `Sources/SiftCore/Events.swift`

```swift
public enum EventKind: String, Codable {
    case move          // an item moved between stages
    case optimize      // a file was losslessly shrunk
    case pinNormalize  // a relative/malformed pin became absolute
    case pinExpire     // a pin lapsed; clock restarted
    case pending       // dry-run only: what *would* happen, never written to disk
}

public struct SiftEvent: Codable, Equatable {
    public let ts: String            // ISO8601
    public let kind: EventKind
    public let path: String          // the subject
    public let to: String?           // move destination
    public let before: Int?          // optimize: bytes before
    public let after: Int?           // optimize: bytes after
    public let remainingDays: Int?   // pending: days until it moves (0 = now)
    public let detail: String?       // pin tag text, stage name
}

public struct EventLog {
    public init(path: String)
    public func append(_ event: SiftEvent)   // best-effort; never throws
}

/// `<directory of settings.log>/events.jsonl` — colocated with the text log so
/// it rotates through the same rule.
public func eventLogPath(for config: Config) -> String

/// Reads a JSONL file, skipping malformed lines rather than failing.
public func readEvents(at path: String) -> [SiftEvent]

/// Live file plus `Archive/events*.jsonl`, sorted newest first.
public func readAllEvents(logDirectory: String) -> [SiftEvent]
```

`append` mirrors `Logger`'s approach: create the directory if needed, open by
path, seek to end, write one line. Failures are swallowed — a missing history
entry must never break a run.

### 4.2 Wiring

`Scanner` and `OptimizePass` each gain an `event: (SiftEvent) -> Void` sink
alongside their existing `log:` closure, defaulting to a no-op.

A default is safe here in a way it was not for `setSiftTag(preserving:)`: the
worst case of a missing event sink is an absent history row, not data loss or a
destroyed tag. That asymmetry is the reason one has a default and the other
deliberately does not.

Emission points, all *after* the existing `dryRun` guards so real actions and
dry runs stay separated:

| Site | Event |
|---|---|
| `Scanner.moveItem`, after a successful move + restamp | `.move(path: src, to: dst, detail: stage)` |
| `Scanner.writeKeepTag`, after the tag is written | `.pinNormalize(path:, detail: tagText)` |
| `Scanner.retirePin`, after the tag is cleared | `.pinExpire(path:)` |
| `OptimizePass.process`, after the atomic replace | `.optimize(path:, before:, after:)` |
| `Scanner.process`, when an item is evaluated and not moved | `.pending(path:, remainingDays:)` |

The `.pending` case is emitted from `process()` itself, not from
`tagCountdown()`. `tagCountdown` only runs for items in a terminal destination
with tagging enabled, so wiring there would silently omit every live-folder item
counting down toward Review — precisely the rows a "what's due next" view most
needs.

### 4.3 Dry-run separation

`CLI.cmdRun` wires the file appender **only when not dry-running**:

```swift
let events = EventLog(path: eventLogPath(for: config))
let eventSink: (SiftEvent) -> Void = dryRun ? { _ in } : { events.append($0) }
```

So `.pending` events never reach disk, and `sift status` / `--dry-run` remain
byte-for-byte read-only — an invariant already asserted by existing tests.

### 4.4 Rotation interplay

`events.jsonl` sits in `~/Library/Logs/Sift/`, which is a watched folder with the
7-day rotation rule, so it ages into `Archive/` exactly like `sift.log` —
bounded growth, no new mechanism, retention controlled by emptying `Archive/`.
`onConflict: rename` yields `events 2.jsonl`, `events 3.jsonl`; `readAllEvents`
globs `events*.jsonl` in `Archive/` and merges.

Volume check: 242 moves + 101 optimizes over roughly two weeks on the deployed
machine ≈ 350 events ≈ 50 KB of JSONL. Rotation is about tidiness, not size.

## 5. Part 2 — `sift report`

### 5.1 CLI

```text
sift report [--config <path>] [--out <path>] [--open]
```

- Default output: `~/Library/Caches/com.brandonshutter.sift/report.html`.
  **Not** the Logs directory — that folder is watched, so a report written there
  would be aged into `Archive/` after 7 days. `Caches` is also the conventional
  home for a regenerable artifact.
- `--open` hands the file to `/usr/bin/open` via the existing `runProcess`.
- Exit 0 on success; 1 on config error, matching the other commands.

### 5.2 New: `Sources/SiftCore/Report.swift`

```swift
public struct ReportData {
    public let config: Config
    public let pending: [SiftEvent]   // .pending, from a dry-run Scanner pass
    public let history: [SiftEvent]   // everything else, newest first
}

public func renderReport(_ data: ReportData, generated: Date) -> String
```

Pure string building — no filesystem access, so it is fully unit-testable. The
CLI gathers `ReportData` (dry-run `Scanner` with a collecting sink, plus
`readAllEvents`) and writes the returned string.

### 5.3 Page contents

One self-contained HTML file: inline `<style>`, no scripts, no external assets,
`prefers-color-scheme` for light and dark.

1. **Summary** — files optimized, bytes reclaimed, items moved, window covered.
2. **Watched folders & rules** — path, ignore list, threshold, destination,
   `sortInto` / `onConflict`, straight from the config.
3. **Due next** — the `.pending` rows sorted by `remainingDays` ascending, so
   items moving on the next pass sort first.
4. **Activity** — history newest first: timestamp, kind, path, and either the
   destination or a before → after byte delta with a percentage.
5. **Settings** — interval, log path, tagging prefix, optimize block.

Paths are displayed with the home directory abbreviated to `~`. All text is
HTML-escaped — filenames legitimately contain `&`, `<`, and quotes.

## 6. Error handling

| Condition | Behavior |
|---|---|
| Event log missing or unreadable | treated as empty history; report still renders |
| Malformed JSONL line | skipped; remaining lines still parsed |
| `append` fails (permissions, disk) | silently ignored; the run continues |
| Output directory missing | created with intermediates |
| `--out` path unwritable | `ERROR` to stderr, exit 1 |
| No events at all yet | report renders with empty-state text, not a crash |

## 7. Testing

- `EventsTests`: round-trip encode/decode; `append` creates the directory and
  writes exactly one line per event; `readEvents` skips malformed lines and
  tolerates a missing file; `readAllEvents` merges live + archived and sorts
  newest first; `eventLogPath` derives from the log's directory.
- `ScannerTests`: a move emits exactly one `.move` with correct `from`/`to`; pin
  normalization and expiry emit their kinds; a dry run emits `.pending` with the
  right `remainingDays` and emits no action events; countdown tagging emits
  nothing.
- `OptimizePassTests`: a successful optimize emits one `.optimize` carrying real
  byte counts; a failed or skipped one emits nothing.
- `ReportTests`: `renderReport` escapes `&<>"` in paths; renders empty state
  without crashing; totals sum correctly; pending rows sort by `remainingDays`;
  output contains no `http://` or `https://` reference (self-containment).
- `CLITests`: `report` is a recognized command and appears in usage.

## 8. Files touched

| File | Change |
|---|---|
| `Sources/SiftCore/Events.swift` | new |
| `Sources/SiftCore/Report.swift` | new |
| `Sources/SiftCore/Scanner.swift` | `event:` sink + 4 emission points |
| `Sources/SiftCore/OptimizePass.swift` | `event:` sink + 1 emission point |
| `Sources/SiftCore/CLI.swift` | wire sinks, `report` command, usage text |
| `Tests/…` | one test file per new source file, plus additions above |
| `README.md` | `sift report` and the event log |
| `CLAUDE.md` | module map, event-log invariants |
