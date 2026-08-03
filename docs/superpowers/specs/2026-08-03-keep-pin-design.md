# Sift — Keep Pin Design Spec

**Date:** 2026-08-03
**Status:** Approved for planning

## 1. Overview

A Finder tag that exempts an item from Sift's aging pipeline. Tagging an item
`Sift · Keep` pins it in place: it never moves from `~/Desktop` / `~/Downloads`
into `… to Review`, and never advances from `… to Review` into `… to Delete`.

The pin supports an optional expiry (`Sift · Keep 30d`), after which the item
resumes normal aging with a full grace period rather than moving immediately.

This is the per-item, Finder-native counterpart to the existing `folders[].ignore`
list, which exempts items statically by filename from JSON.

## 2. Goals

- Exempt an item from aging by applying a Finder tag — no config edit, no CLI.
- Support both indefinite pins and pins with an expiry date.
- Never silently move an item the user tried to protect. Every ambiguous input
  resolves toward "stay pinned".
- Cost nothing in steady state: a settled pin performs one `getxattr` per pass
  and no writes.
- Respect `--dry-run` / `sift status` — the feature adds three new write paths,
  all of which must be suppressed.

## 3. Non-Goals

- No new config surface. `Keep` is hardcoded; `settings.tagging.prefix` already
  governs the namespace.
- No CLI subcommand for pinning (`sift keep <path>`). Finder is the interface.
- No pin inheritance. Sift moves whole items and never descends into user
  content, so pinning a folder pins the folder — there is no subtree to consider.

## 4. Tag Grammar

A tag entry belongs to Sift only if, after stripping the `<prefix> · ` prefix and
the `\n<colorIndex>` suffix, its **first whitespace-delimited token is exactly
`Keep`**. Token equality — not prefix matching — so a user's own `Sift · Keepsakes`
tag is left completely alone.

| Tag in Finder | Parsed as | Behavior |
|---|---|---|
| `Sift · Keep` | `.indefinite` | Pinned forever. No writes. |
| `Sift · Keep 30d` | `.relative(2592000)` | Normalize to absolute, then pinned. |
| `Sift · Keep until 2026-09-02` | `.until(2026-09-02)` | Pinned through Sep 2. No writes. |
| `Sift · Keep 3x` | `.malformed("3x")` | WARN, pin, normalize to `Sift · Keep`. |
| `Sift · Keep until Sep 2` | `.malformed("until Sep 2")` | WARN, pin, normalize to `Sift · Keep`. |
| `Sift · Keepsakes` | not Sift's | Ignored silently. Ages normally. |
| `Sift · 3d → Delete` | not a keep tag | Ignored by this feature. |

Durations reuse the existing `parseDuration` (`<n><s\|m\|h\|d>`). Dates are ISO
`YYYY-MM-DD` only.

### 4.1 Expiry semantics

A Finder tag carries no timestamp, so Sift cannot know when a tag was applied,
and cannot decrement a counter per pass — launchd coalesces `StartInterval`
across sleep, so pass frequency is irregular (measured: 128 passes in 13 days on
an hourly interval). The expiry is therefore stored as an **absolute date in the
tag text itself**, written once on the first pass that sees a relative duration.

Expiry is **inclusive of the named day**: `Keep until 2026-09-02` is active for
all of Sep 2 and lapses at the start of Sep 3. Concretely, a relative duration is
resolved as `endOfDay(now + duration)` in the local calendar, which rounds every
pin *up*. Sub-day durations (`Keep 6h`) round up to end-of-today; this is
accepted coarseness, not a bug.

## 5. Behavior Specification

### 5.1 Decision flow

Evaluated in `Scanner.process()`, **before** `dateAdded(of:)` is read — the
expiry path restamps Date Added, so reading it earlier would use a stale value.

```bash
process(item)
  ├─ parseKeepTag(rawTags(of: item), prefix:)
  │    nil          → fall through to normal aging
  │    .indefinite  → clear stale countdown if present; return (no move)
  │    .relative(d) → write "Keep until <endOfDay(now+d)>"; return (no move)
  │    .malformed   → WARN; write "<prefix> · Keep"; return (no move)
  │    .until(date)
  │       now ≤ date → clear stale countdown if present; return (no move)
  │       now > date → remove keep tag; setDateAdded(now); fall through
  └─ existing: dateAdded → ruleMatches → moveItem / tagCountdown
```

### 5.2 Pinned items carry no countdown

Every pinned branch returns before `tagCountdown()` is reached, so a pinned item
can never display a `Sift · Nd → Delete` tag. Any stale countdown left from
before the pin was applied is cleared when the pin is first seen.

The clear is **conditional on a countdown tag actually being present** in the tag
list already read for parsing. A settled pin therefore performs no writes.

### 5.3 Expiry lands softly

On expiry Sift removes the keep tag and restamps Date Added to now. Because the
item is then zero days old against a 7-day threshold, it cannot match the rule on
that same pass; it picks up a fresh `Sift · 7d → Delete` countdown instead. This
reuses the existing restamp-on-move invariant rather than adding a special case.

Without this, an item pinned inside a Review folder would be ~31 days old against
a 7-day threshold the instant its pin lapsed, and would move to Delete on the
very next pass with no visible warning.

### 5.4 Interaction with the double-hop guard

A pinned item is never moved, so it is never inserted into `movedThisRun`. An
expired item is restamped and cannot match on the same pass, so it cannot move
twice either. The guard is unaffected.

### 5.5 Dry-run

Three new write paths — normalize, malformed-normalize, expire — are all gated on
`dryRun` and log instead:

```text
DRY normalize <path>: Sift · Keep until 2026-09-02
DRY normalize <path>: Sift · Keep   (unparseable duration "3x")
DRY expire <path>: keep tag lapsed, resuming aging
```

## 6. Components

### 6.1 New: `Sources/SiftCore/Keep.swift`

Pure parsing, no I/O.

```swift
public enum KeepTag: Equatable {
    case indefinite
    case relative(TimeInterval)
    case until(Date)
    case malformed(String)
}

/// Parses the first keep tag out of a raw user-tags list.
public func parseKeepTag(_ entries: [String], prefix: String, calendar: Calendar) -> KeepTag?

/// True when a raw tag entry is Sift's keep tag. Used to protect it from being
/// stripped when the countdown tag is rewritten.
public func isKeepTag(_ entry: String, prefix: String) -> Bool

/// Renders an absolute expiry back to tag text.
public func keepTagText(until date: Date, prefix: String) -> String
```

### 6.2 Changed: `Sources/SiftCore/FSMetadata.swift`

`setSiftTag` currently strips every entry beginning with `<prefix> · `, which
would eat the keep tag on the next countdown rewrite. It gains an explicit
predicate parameter:

```swift
public func setSiftTag(
    _ path: String, text: String?, color: Int, prefix: String,
    preserving: (String) -> Bool
) throws
```

No default value: with three call sites, a silent default is precisely how the
keep tag would get eaten again in a later change. `FSMetadata` stays a dumb
syscall wrapper and gains no knowledge of keep semantics — the predicate is
supplied by the caller.

### 6.3 Changed: `Sources/SiftCore/Scanner.swift`

`process()` gains the keep branch from §5.1. A private helper resolves the tag
into a pin/no-pin decision and performs any normalization or expiry writes.

## 7. Error Handling

| Condition | Behavior |
|---|---|
| Unparseable duration or date after `Keep` | WARN, pin indefinitely, normalize tag to `<prefix> · Keep` |
| `getxattr` fails / no tags | `rawTags` returns `[]` → no keep tag → normal aging |
| `setxattr` fails during normalize | `ERROR normalize <path>: <err>`; item stays pinned this pass (tag unchanged, retried next pass) |
| `setattrlist` fails during expiry restamp | `ERROR stamp <path>: <err>`; keep tag already removed, so the item ages on its original clock — matches existing move-path behavior |
| Multiple keep tags on one item | First match wins; the others are left alone |

The unparseable case is the load-bearing one: a typo must never cause a file the
user tried to protect to be moved.

## 8. Testing Strategy

TDD — branchy logic with a data-safety failure mode.

**`Tests/SiftCoreTests/KeepTests.swift`** (new) — the §4 grammar table, plus:
custom prefix; entries carrying the `\n6` color suffix; `Keepsakes` rejected;
expiry boundary (active on the named day, lapsed the day after); `keepTagText`
round-trips through `parseKeepTag`.

**`ScannerTests.swift`** — behaviors:
- pinned item does not move out of Desktop
- pinned item does not advance Review → Delete
- stale countdown tag cleared when a pin is seen
- `Keep 30d` normalizes to an absolute date exactly once; a second pass writes nothing
- expired pin: tag removed, Date Added restamped, item does *not* move that pass
- expired pin picks up a fresh `7d → Delete` countdown
- malformed pin: item stays, tag normalized to `Sift · Keep`
- `--dry-run` leaves tags and Date Added untouched

**`FSMetadataTests.swift`** — a countdown rewrite preserves the keep tag while
still replacing Sift's other tags.

## 9. Files Touched

| File | Change |
|---|---|
| `Sources/SiftCore/Keep.swift` | new |
| `Tests/SiftCoreTests/KeepTests.swift` | new |
| `Sources/SiftCore/Scanner.swift` | keep branch in `process()` |
| `Sources/SiftCore/FSMetadata.swift` | `preserving:` parameter |
| `Tests/SiftCoreTests/ScannerTests.swift` | new cases |
| `Tests/SiftCoreTests/FSMetadataTests.swift` | preservation case |
| `README.md` | user-facing docs for the tag grammar |

`sift.example.json` and `ExampleConfigTests` are untouched — the feature adds no
config field.
