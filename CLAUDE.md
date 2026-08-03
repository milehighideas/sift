# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sift is a macOS file-automation tool (a homegrown Hazel) with three jobs, run in this order
by `sift run`:

1. **Optimize** — losslessly shrink images in every watched folder (`OptimizePass`), skipping
   anything tagged `Keep OG` and anything already tagged `Sift · Optimized`.
2. **Age** — move items through a two-stage **Review → Delete** pipeline keyed on macOS
   *Date Added*: 7 days untouched → `… to Review/<Category>/`, 7 more days →
   `… to Delete/<Category>/` (`Scanner`).
3. Sift **never deletes** — the user empties Delete folders manually.

Its own log rotates through the same aging machinery (a plain `folders[]` entry in the
example config). See `README.md` for user-facing docs.

## Commands

- Build: `swift build` (release: `swift build -c release`)
- Test: `swift test` (full suite, ~3s)
- Format lint (non-mutating): `swift-format lint --strict <files>`
- Shell lint: `shellcheck --severity=warning <files>`
- Single test: `swift test --filter SiftCoreTests.DurationTests`

Formatting uses **Apple's `swift-format`** (`brew install swift-format`) — NOT SwiftLint or the
Nick Lockwood SwiftFormat. Config is pinned in `.swift-format` (4-space indent, 100-col). The whole
tree conforms and the pre-commit runs `lint --strict`, so keep it clean: run
`swift-format format -i -r Sources Tests` before committing Swift changes.

## Repo setup

`.envrc` (direnv) sets `core.hooksPath=.githooks` and switches the `gh` account to `milehighideas`.
Run `direnv allow` once — the shared pre-commit hook only activates through this. The hook runs
`swift build` + `swift test` when Swift/`Package.resolved` is staged, `swift-format lint --strict`
on staged Swift files, and `shellcheck` on shell scripts. Override with `git commit --no-verify`.

Swift 5.9, macOS 12+. Targets: `SiftCore` (lib), `sift` (executable), `SiftCoreTests`.

**Dependencies:** zero SwiftPM packages — Foundation, Darwin, CoreGraphics/ImageIO only (all system
frameworks). The optimize pass shells out to *optional* external CLI tools (`oxipng`, `jpegtran`,
`gifsicle`) discovered at runtime from `$PATH` then ImageOptim.app's bundle. A missing tool is a
logged skip, never an error — do not turn one into a hard dependency.

## Config

JSON at `~/.config/sift/sift.json` (`sift.example.json` is the template). JSON has no comments —
document fields in the README, not inline. `Config.validate()` is deliberately restrictive:
**one rule per folder, one action per rule**; only `attr: date_added` + `op: older_than`; `sortInto`
∈ {`category`,`none`}; `onConflict` ∈ {`rename`,`replace`,`skip`}; `optimize.level` ∈ 0…6 and
`optimize.skipTag` non-empty. Durations are `<n><s|m|h|d>` (e.g. `7d`).

`settings.optimize` is **optional and must stay optional** — configs written before the feature must
keep decoding. `ExampleConfigTests` asserts the shipped example passes validation and dogfoods log
rotation — **update the example and this test together**.

## The tag vocabulary

All tags live in the user-tags xattr (the `com.apple.metadata` domain; `FSMetadata` builds the full
key by concatenation). Entries carry a `\n<colorIndex>` suffix, so always compare on the name portion.

| Tag | Kind | Meaning |
| --- | --- | --- |
| `Sift · Nd → Delete` / `→ Archive` | transient | countdown, rewritten every pass (orange, 7) |
| `Sift · Delete` / `Sift · Archive` | transient | terminal-stage marker (red, 6) |
| `Sift · Keep` / `Keep 30d` / `Keep until <ISO>` | **persistent** | aging pin (red, 6) |
| `Keep OG` (bare) or `Sift · Keep OG` | **persistent** | protects file *bytes* from optimize; **not** a pin |
| `Sift · Optimized` | **persistent** | optimize idempotency marker (green, 2) |

## Invariants — do not break these

### Aging

- **Whole-item moves only.** Files, folders, and bundles (`.rtfd`, `.app`, …) move intact. Sift never
  descends into a folder/bundle it did not create (destination folders are the one exception, descending
  exactly one level into its own category subfolders). Never flatten or recurse into user content.
- **Double-hop guard** (`Scanner`): an item moved once this run is tracked in `movedThisRun`; a second
  matching move is skipped so nothing cascades Review→Delete in a single pass.
- **Clamped elapsed age** (`Rules.remainingDays`): elapsed is `max(0, now - dateAdded)` (guards clock skew);
  the countdown never goes negative and reports 0 only when the item should move now.
- **Date-Added restamp**: after moving, `setDateAdded(..., to: now)` resets the item so the next stage's
  countdown starts fresh (raw `setattrlist`/`ATTR_CMN_ADDEDTIME`).
- **Lexical path normalization** (`standardizePath`): expands `~`, resolves `.`/`..`, and touches
  **nothing on disk**. `NSString.standardizingPath` resolves symlinks only for paths that *already
  exist*, so it returned different answers before and after Sift created a destination mid-run —
  which silently disabled the Review-stage descent and the double-hop guard. Never reintroduce it.

### Tags

- **`isPersistentSiftTag` is the predicate** every `setSiftTag(preserving:)` call site passes (or
  `isOptimizedTag` where the pin itself is being rewritten/cleared). `setSiftTag` strips all
  `<prefix> · ` entries, so an ad-hoc `{ _ in false }` closure silently eats pins and markers.
  Four call sites had this bug; do not add a fifth.
- **`setSiftTag` vs `addSiftTag`**: `setSiftTag` *replaces* Sift's transient tags; `addSiftTag`
  *appends* one persistent tag idempotently. Markers use `addSiftTag`.
- **`Keep OG` is not a pin.** `parseKeepTag` returns nil for it while `isKeepTag` returns true —
  the two must diverge. Collapsing them back reintroduces one of two bugs: either `Sift · Keep OG`
  pins the file forever *and* rewrites the tag to `Sift · Keep` (erasing the marker it was asked to
  honour), or the tag gets stripped on the next countdown rewrite.
- **A malformed pin still pins.** Unparseable text after `Keep` → WARN + indefinite pin, normalized
  to `<prefix> · Keep`. A typo must never cause a protected file to be moved.
- **Relative pins normalize exactly once** to an absolute date stored in the tag. A Finder tag has no
  timestamp and launchd coalesces runs across sleep, so a per-pass countdown would burn days at
  random speed.

### Optimize

- **No tool writes in place.** Every format goes input → temp → verify → atomic `rename(2)` →
  restore Date Added + captured xattrs. In-place semantics differ per tool (oxipng preserves the
  inode; jpegtran cannot write in place at all), and getting one wrong resets the aging clock and
  wipes Finder tags. Verified: a temp+move without restore reset Date Added to *now* and destroyed
  all tags.
- **Verification before replacement**: candidate must decode with
  `CGImageSourceGetStatus == .statusComplete` (a truncated file still yields a partial image
  otherwise), match the original's dimensions, and be strictly smaller.
- **Marker discipline**: withhold `Sift · Optimized` on tool failure, timeout, and unreadable
  original (a partial download) so those retry; *write* it when the tool simply cannot shrink the
  file so that case never retries. The marker is written regardless of `tagging.enabled` — it is
  functional state, not cosmetic.
- **Subprocesses need a hard timeout** (`Shell.runProcess`). launchd will not start a second
  instance of the label, so one wedged tool would silently stop all aging and optimizing forever.
- **`FileOptimizer` is the only per-format seam.** Adding a type (e.g. PDF) must be one registry
  entry — extensions, tool names, argument builder, verify closure — and nothing else.

### launchd & logging

- **`watchPaths(for:)` never emits a move destination or the log's own directory.** Watching the
  folder Sift logs into is a guaranteed feedback loop (write → wake → run → write). This is an
  invariant, not a config knob.
- **`Logger` echoes to stdout only when stdout is a TTY.** Under launchd, `StandardOutPath` *is* the
  log file, so an unconditional `print` writes every line twice through two descriptors with
  independent offsets — they interleave and truncate each other (5,592 corrupted lines before this
  was caught).

## Module map (`Sources/SiftCore/`)

**Aging:** `Scanner` (the pass, move orchestration, double-hop guard, keep resolution) ·
`Rules` (matching, `remainingDays`) · `Actions` (move + conflict handling) ·
`Category` (extension → category) · `Keep` (tag grammar, pin parsing, tag predicates)

**Optimize:** `OptimizePass` (walk + temp-file pipeline) · `Optimize` (settings, `FileOptimizer`
registry, tool discovery, image verify) · `Shell` (subprocess + timeout)

**Plumbing:** `CLI` (arg parse/dispatch) · `Config` (load, `validate`, `standardizePath`) ·
`Duration` (parse) · `FSMetadata` (Date Added, tags, xattr capture/restore) ·
`Launchd` (agent `com.brandonshutter.sift`, plist, `watchPaths`) · `Logger`

One test file per source file. Subprocess behavior is tested with **stub shell scripts** written by
the test, so the suite passes on machines without the optimizer tools; real-tool tests gate on
`XCTSkipIf(findTool(...) == nil)`.

## Specs & plans

Design specs live in `docs/superpowers/specs/`, implementation plans in `docs/superpowers/plans/`.
Read the relevant spec before changing a feature — they record *why* each invariant above exists,
usually with the measurement that motivated it.
