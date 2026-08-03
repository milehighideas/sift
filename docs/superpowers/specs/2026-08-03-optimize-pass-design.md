# Sift — Optimize Pass Design Spec

**Date:** 2026-08-03
**Status:** Approved for planning

## 1. Overview

A second pass in `sift run`, executed **before** the aging pass, that losslessly
shrinks image files in every folder Sift watches — replacing the Hazel +
ImageOptim.app workflow. Files tagged `Keep OG` are left untouched; files that
have been processed carry a `Sift · Optimized` Finder tag and are skipped on
later passes. launchd `WatchPaths` triggers a run the moment something lands in
Desktop or Downloads, restoring Hazel's immediacy.

The pass is built as a **format-agnostic pipeline with pluggable per-format
optimizers**. Images (png/jpg/gif) ship now; PDF compression is a planned later
addition that must slot in as one new registry entry, with no pipeline changes.

## 2. Goals

- Optimize png/jpg/jpeg/gif in all watched folders and their move destinations
  (live folders, Review, Delete), including the existing backlog (~2,232 files).
- Losslessly: pixels identical, metadata preserved (`--strip safe`, `-copy all`).
- Skip any item tagged `Keep OG` (bare) or `Sift · Keep OG` (namespaced).
- Mark processed files with the Finder tag `Sift · Optimized`; marked files are
  skipped without spawning a subprocess. Removing the tag re-queues the file.
- Run immediately on new arrivals via launchd `WatchPaths`, while `StartInterval`
  keeps the aging countdown ticking.
- Zero SwiftPM dependencies. Optimizers are external CLI tools discovered at
  runtime; a machine without them degrades to a logged skip, never an error.
- Never damage a file: the original is only replaced by a verified-good,
  strictly-smaller result, and Date Added + all xattrs survive the swap.

## 3. Non-Goals

- No lossy optimization (no pngquant/guetzli), no resizing, no format conversion.
- No descent into user folders or bundles — a folder of images dropped on the
  Desktop is opaque to Sift, per the whole-item invariant. (Hazel differed here;
  the invariant wins.)
- No optimizer for heic/webp/svg/etc. in v1 — extensions without a registry
  entry are not candidates and are never marked.
- No re-optimization of edited files: the marker is presence-only. Removing the
  tag manually is the re-queue mechanism (matches the Hazel label behavior).
- No resident daemon / FSEvents. launchd does the watching; Sift stays a
  stateless one-shot.
- PDF is out of scope for this iteration (see §11 for the seam it will use).

## 4. Components

### 4.1 New: `Sources/SiftCore/Optimize.swift`

Settings, the optimizer registry, and tool discovery. Pure logic + filesystem
probes; no subprocess execution.

```swift
public struct OptimizeSettings: Codable {
    public let enabled: Bool
    public let skipTag: String        // default "Keep OG"
    public let level: Int             // oxipng -o level, 0...6, default 2
}

public struct FileOptimizer {
    public let name: String                               // "png", "jpeg", "gif"
    public let extensions: Set<String>                    // lowercased
    public let toolNames: [String]                        // preference order
    public let arguments: (String, String, Int) -> [String]  // (in, out, level)
    public let verify: (URL, URL) -> Bool                 // (original, candidate)
}

public let imageOptimizers: [FileOptimizer]               // png, jpeg, gif

/// $PATH first, then ImageOptim.app's bundled GPL resources, else nil.
public func findTool(named: String, searchPath: [String]) -> String?
```

Registry entries:

| name | extensions | tool | invocation |
|---|---|---|---|
| png | png | `oxipng` | `--out <out> --force -o <level> --strip safe <in>` |
| jpeg | jpg, jpeg | `jpegtran` | `-copy all -optimize -progressive -outfile <out> <in>` |
| gif | gif | `gifsicle` | `-O2 -o <out> <in>` |

`--force` matters: oxipng otherwise suppresses output that is not smaller; Sift's
own size check (§5 step 5) is the single arbiter, applied uniformly to all tools.

Tool discovery order, resolved once per run and cached:
1. `$PATH` (via `PATH` env split, first executable match)
2. `/Applications/ImageOptim.app/Contents/Frameworks/ImageOptimGPL.framework/Versions/A/Resources/`
3. nil → the format is logged once (`SKIP no optimizer for png`) and its files
   are left unmarked, so installing a tool later takes effect automatically.

`verify` for images: decode candidate via ImageIO (`CGImageSource`), require an
image at index 0 and pixel dimensions equal to the original's. (PDF will supply
its own closure; the pipeline never knows the difference.)

### 4.2 New: `Sources/SiftCore/OptimizePass.swift`

The walk and the per-file pipeline. Mirrors `Scanner`'s shape: struct holding
`config`, `dryRun`, `log`, plus the resolved tool table.

**Folder set:** every `folders[].path` plus every distinct move destination,
deduplicated via `standardizePath`. Live folders honor their `ignore` lists.
Destination folders (Review/Delete) get the same one-level descent into Sift's
own category subfolders that `Scanner.enumerateItems` performs. Only plain files
whose extension matches a registry entry are candidates; directories and bundles
are never entered.

**Per-file pipeline** (§5) runs candidates sequentially. No throttling: the
first pass grinds the backlog (~60 min measured at level 2); every later pass is
marker-skips only (~2 s).

### 4.3 New: `Sources/SiftCore/Shell.swift`

Minimal Foundation `Process` wrapper:

```swift
public struct ShellResult { public let status: Int32; public let timedOut: Bool }
public func runProcess(_ launchPath: String, _ args: [String],
                       timeout: TimeInterval) -> ShellResult
```

Hard per-file timeout (120 s): a hung tool is killed and the file is skipped
**without marking**, so it is retried next pass rather than falsely done. This
guard is load-bearing — launchd never starts a second instance of the label, so
one wedged subprocess would otherwise silently stop aging and optimizing forever.

### 4.4 Changed: `Sources/SiftCore/FSMetadata.swift`

Two additions, one reframing:

- `captureXattrs(of:) -> [(name: String, data: Data)]` and
  `restoreXattrs(_:to:)` — raw listxattr/getxattr/setxattr round-trip.
- `addSiftTag(_ path:, text:, color:, prefix:)` — idempotent append: removes
  only an existing entry with the same name, touches nothing else. Used for the
  `Sift · Optimized` marker.
- `setSiftTag` keeps replace semantics for Sift's **transient** tags (countdown,
  terminal) but its `preserving:` callers converge on one shared predicate (§4.5)
  covering all **persistent** tags. No more per-call-site ad-hoc closures.

### 4.5 Changed: `Sources/SiftCore/Keep.swift`

- `parseKeepTag`: a body whose first token is `Keep` and whose remainder is
  exactly `OG` is **not a pin** — returns nil for pin purposes. This closes the
  measured trap where `Sift · Keep OG` pinned a file forever and erased the tag.
- New `isKeepOGTag(_ entry:, prefix:) -> Bool`: true for bare `Keep OG` (or the
  configured `skipTag` verbatim) and for `<prefix> · Keep OG`.
- New `isPersistentSiftTag(_ entry:, prefix:) -> Bool`: true for every `Keep…`
  form and for `Optimized`. This is the one predicate `setSiftTag` callers pass.

The bare tag needs no preservation logic: `setSiftTag` only strips
prefix-matching entries, so `Keep OG` (no prefix) survives all rewrites already.

### 4.6 Changed: `Config.swift`, `CLI.swift`, `Launchd.swift`

- `Settings` gains `optimize: OptimizeSettings?` — **optional**, so the existing
  deployed `sift.json` keeps decoding. Absent = feature off. Validation: `level`
  in 0...6, `skipTag` non-empty.
- `CLI.runCommand`: construct and run `OptimizePass` before `Scanner` when
  `optimize?.enabled == true`. `sift status` includes the pass in dry-run form
  (`DRY optimize …` lines).
- `Launchd.plistContents`: add `WatchPaths` (the expanded paths of folders that
  are **not** move destinations — i.e. Desktop and Downloads, not Review) and
  `ThrottleInterval` 30. `StartInterval` stays: aging must tick when nothing
  changes.

## 5. The per-file pipeline

For each candidate file:

```bash
0. rawTags read once →
     contains skip tag (Keep OG / Sift · Keep OG)  → SKIP (no marker)
     contains "Sift · Optimized"                    → skip silently, no log
1. extension in an in-progress set (crdownload, download, part, partial, tmp)
     → SKIP (WatchPaths can fire mid-download)
2. capture Date Added + all xattrs
3. copy nothing — run tool: input = original, output = <dir>/.sift-opt-<uuid>
     (same directory ⇒ same volume ⇒ rename(2) is atomic)
4. tool failed, timed out, or wrote nothing → delete temp, SKIP without marker
5. judge the candidate:
     original fails verify()          → delete temp, SKIP without marker
                                        (likely a partial download; retry later)
     candidate empty or fails verify() → delete temp, no marker, log ERROR
                                        (tool produced garbage; visible, retryable)
     candidate not smaller            → delete temp, MARK original as optimized
                                        (cannot shrink — done, never retried)
6. rename temp over original (atomic)
7. restore Date Added (setDateAdded) and captured xattrs
8. addSiftTag "Sift · Optimized" (color 2 = green)
9. log "OPT <path>: <orig> -> <new> bytes (<pct>%)"
```

Dry run: steps 0–1 evaluate, then log `DRY optimize <path>` and stop. No temp
files, no subprocesses, no tags.

The marker is written regardless of `settings.tagging.enabled` — it is
functional state (the idempotency ledger), not cosmetic. Measured cost of *not*
having it: 1.6 s per already-optimized file, ×2,232 files, every hour.

## 6. Ordering and interaction with aging

- Optimize runs first so a new screenshot is shrunk before it can ever be moved;
  the aging pass then behaves identically on optimized and untouched files
  because Date Added was restored (§5 step 7).
- A file may be optimized and moved to Review by the same run's aging pass;
  xattr restoration keeps the marker through the move (moves preserve xattrs;
  the replace-under-move race is not possible because the passes are sequential).
- The double-hop guard is untouched: optimization never moves files.
- WatchPaths self-trigger: the optimize pass rewrites files at the watched
  folders' top level, and aging moves files out of them — either fires one
  follow-up run. That run finds everything marked and nothing to age (~2 s) and
  writes nothing at the top level, so the sequence converges. `ThrottleInterval`
  30 bounds the burst rate.

## 7. Error handling

| Condition | Behavior |
|---|---|
| No tool found for a format | log once per run, files unmarked (retry when installed) |
| Tool exits non-zero / empty output | delete temp, skip, **no marker**, log ERROR |
| Tool exceeds 120 s | kill, delete temp, skip, **no marker**, log ERROR timeout |
| Output not smaller | delete temp, **mark** (done, not retryable), no OPT log |
| Output fails decode/dimension verify | delete temp, no marker, log ERROR verify |
| Original fails decode | skip, no marker (partial download; retry later) |
| xattr restore fails after rename | log ERROR; file content is correct, marker still written |
| Date Added restore fails | log ERROR stamp (matches existing move-path behavior) |

Failure direction is always "leave the original alone"; the only state a failed
file gains is a log line.

## 8. Config

```json
"optimize": { "enabled": true, "skipTag": "Keep OG", "level": 2 }
```

`sift.example.json` gains the block; `ExampleConfigTests` updated in the same
commit. Level 2 default per measurement: 41% mean savings at 1.6 s/MB-file vs
43% at 5.5 s for level 4.

## 9. Testing strategy

TDD throughout. Subprocess-dependent behavior is tested against **stub tool
scripts** written into the test's temp dir (a shell script that truncates its
input to half size, one that exits 1, one that sleeps past a short timeout), so
the suite passes on machines without oxipng. One integration test per real tool
is gated on `XCTSkipUnless(findTool(…) != nil)`.

- `OptimizeTests`: registry contents; discovery order (fake PATH dir beats fake
  bundle dir beats nil); argument construction; verify() accepts a valid PNG and
  rejects truncated bytes.
- `ShellTests`: exit-status capture; timeout kills and reports.
- `OptimizePassTests`: skip via `Keep OG`, via `Sift · Keep OG`, via marker;
  marker written on success and on not-smaller; no marker on tool failure /
  timeout / undecodable original; Date Added + user tags + pin survive
  optimization; dry-run leaves bytes and tags untouched; destination folders
  (Review/Delete category subfolders) are walked; user folders and bundles are
  not entered; in-progress extensions skipped.
- `KeepTests` additions: `Keep OG` bodies are not pins; `isKeepOGTag` matrix;
  `isPersistentSiftTag` covers Keep/Keep until/Keep OG/Optimized and rejects
  countdown/terminal.
- `FSMetadataTests` additions: xattr capture/restore round-trip; `addSiftTag`
  idempotency; marker survives countdown rewrite and vice versa.
- `LaunchdTests`: plist contains WatchPaths for live folders only, and
  ThrottleInterval.
- `ExampleConfigTests`: example with optimize block validates; config without
  the block still decodes (backward compat with the deployed file).

## 10. Files touched

| File | Change |
|---|---|
| `Sources/SiftCore/Optimize.swift` | new |
| `Sources/SiftCore/OptimizePass.swift` | new |
| `Sources/SiftCore/Shell.swift` | new |
| `Sources/SiftCore/Keep.swift` | Keep OG carve-out, persistent-tag predicate |
| `Sources/SiftCore/FSMetadata.swift` | xattr capture/restore, addSiftTag |
| `Sources/SiftCore/Config.swift` | optional optimize block + validation |
| `Sources/SiftCore/CLI.swift` | run optimize pass before aging |
| `Sources/SiftCore/Launchd.swift` | WatchPaths + ThrottleInterval |
| `Tests/…` | one test file per new source file + additions above |
| `sift.example.json` | optimize block |
| `README.md` | user-facing docs |

## 11. The PDF seam (future, designed-for now)

Adding PDF compression later must require exactly: one `FileOptimizer` value
(extensions `["pdf"]`, tool `qpdf` or `gs`, a `verify` closure opening the
candidate via `CGPDFDocument` and comparing page counts) appended to the
registry, plus its tests. `Keep OG`, the marker, discovery, the pipeline, and
config are already format-neutral. Open question deferred to that iteration:
lossless (`qpdf`, modest) vs lossy (`gs` downsampling, large but degrades
scans) — the `verify` closure supports either; the choice is a product decision.
