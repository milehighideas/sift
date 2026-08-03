# Sift

A tiny macOS file-automation tool. It ages items out of Desktop and Downloads
through a two-stage review→delete pipeline, sorts them into category subfolders,
tags them in Finder with a countdown, and losslessly shrinks images on the way
through. It even rotates its own log using its own rules.

Zero package dependencies — Foundation and system frameworks only. Image
optimization shells out to small CLI tools if they're installed, and quietly
skips if they aren't.

## How it works

1. An item left untouched in `~/Desktop` / `~/Downloads` for **7 days** (by macOS
   *Date Added*) moves into `… to Review/<Category>/`.
2. After **7 more days** in Review, it moves into `… to Delete/<Category>/`.
3. Sift never deletes — you empty the `… to Delete` folders yourself.

Sift moves **whole items** — files, folders, and macOS bundles (`.rtfd`, `.app`,
saved-webpage folders, …) are each moved intact. It never descends into a folder
or bundle it did not create, so nested structure is never flattened or shredded.
Plain folders are grouped under a `Folders/` category; bundles categorize by their
extension (e.g. `.rtfd` → `Documents/`).

Files in a Review folder carry a Finder tag `Sift · Nd → Delete` (orange) that
ticks down each run; files in Delete carry `Sift · Delete` (red).

## Finder tags at a glance

Sift reads and writes a small tag vocabulary. The two you apply yourself are
`Sift · Keep` and `Keep OG`; the rest Sift maintains.

| Tag | Who sets it | Effect |
| --- | --- | --- |
| `Sift · Keep` | you | Never moves. See [Keeping something](#keeping-something). |
| `Sift · Keep 30d` · `Sift · Keep until 2026-09-02` | you | Pinned for a while, then resumes aging. |
| `Keep OG` | you | Never optimized. Does **not** stop aging. |
| `Sift · Optimized` | Sift | Already shrunk; skipped from here on. Remove it to redo. |
| `Sift · Nd → Delete` | Sift | Countdown to the next stage. |
| `Sift · Delete` · `Sift · Archive` | Sift | Sitting in a terminal folder. |

`Sift · Keep` and `Keep OG` are independent and combine fine — one protects the
file's *location*, the other its *bytes*.

## Keeping something

Apply the Finder tag **`Sift · Keep`** to pin an item. A pinned item never leaves
its live folder for Review, and never advances from Review to Delete. Remove the
tag and it resumes aging. This is the per-item counterpart to the `ignore` list in
the config, which exempts items by filename.

Add a duration or a date to pin it only for a while:

| Tag | Meaning |
| --- | --- |
| `Sift · Keep` | Pinned indefinitely. |
| `Sift · Keep 30d` | Pinned for 30 days. Rewritten to an absolute date on the next run. |
| `Sift · Keep until 2026-09-02` | Pinned through Sep 2; resumes aging on Sep 3. |

Durations use the same `<n><s\|m\|h\|d>` format as the config. Dates must be ISO
`YYYY-MM-DD`.

Sift **normalizes a relative pin exactly once**: `Sift · Keep 30d` becomes
`Sift · Keep until <date>` on the next run, and is never rewritten again. A Finder
tag carries no timestamp, so without this Sift could not tell when you applied it.
Expiry is inclusive of the named day, and relative durations round up to the end of
the day they land in — a pin is never cut short.

When a pin lapses, Sift removes the tag and restarts the item's clock, so it gets a
full fresh countdown rather than moving the instant the pin expires. An item pinned
inside a Review folder is therefore visible as `Sift · 7d → Delete` for a week after
its pin runs out.

Two deliberate safety behaviors:

- **A typo still pins.** If the text after `Keep` doesn't parse (`Sift · Keep 3x`,
  or a non-ISO date like `Sift · Keep until Sep 2`), Sift logs a warning, pins the
  item indefinitely, and rewrites the tag to `Sift · Keep` so you can see how it was
  read. A mistyped tag never causes a file to be moved.
- **Only the exact word `Keep` counts.** A tag of your own like `Sift · Keepsakes`
  is not a pin and is left completely alone.

A pinned item never displays a countdown tag; any stale one is cleared the first
time Sift sees the pin.

## Optimizing images

With an `optimize` block in the config, Sift losslessly shrinks images
(png/jpg/jpeg/gif) in every folder it watches — including the Review and Delete
stages — before running the aging pass. Pixels are identical, EXIF and other
metadata are preserved, and both your Finder tags and the *Date Added* aging
clock survive optimization.

```json
"optimize": { "enabled": true, "skipTag": "Keep OG", "level": 2 }
```

- Tag a file **`Keep OG`** (or `Sift · Keep OG`) and Sift will never touch its
  bytes. `Keep OG` protects the file's *contents* only — it does not stop aging.
  Use `Sift · Keep` for that; the two combine fine.
- Processed files are tagged **`Sift · Optimized`** (green). Remove that tag to
  make Sift re-optimize a file.
- `level` is the oxipng effort level (0–6, default 2). Level 4 buys roughly two
  more percentage points for about 3× the CPU.

Optimizers are external tools located at runtime — `oxipng`, `jpegtran`, and
`gifsicle`, taken from `$PATH` (Homebrew) or from ImageOptim.app's bundled
copies. The GUI app is never launched, only its binaries are borrowed. A format
with no available tool is logged once and skipped; nothing breaks, and installing
the tool later makes it take effect on the next run.

Sift never rewrites a file in place. Each candidate is optimized to a temporary
file that must decode cleanly, match the original's dimensions, and be strictly
smaller before it atomically replaces the original — so a failed or truncated
optimization leaves your file exactly as it was.

Installing the agent with optimization enabled adds launchd `WatchPaths` for the
live folders, so a new screenshot or download is optimized within seconds of
landing rather than waiting for the next hourly pass.

**First run:** every existing unoptimized image is processed once, then never
again. Only images Sift can actually see are candidates — top-level items in the
watched folders plus one level inside its own category subfolders. Images nested
in *your* folders are never touched, so the backlog is usually far smaller than a
recursive `find` would suggest (on the author's machine, 104 files in ~90 seconds,
where `find` reported 2,232). Later passes skip tagged files in milliseconds.

If you'd rather not have a background agent do the first sweep, run `sift run`
manually once before `sift install`.

## Log rotation (dogfood)

Sift rotates its own log with its own rules. The log lives in
`~/Library/Logs/Sift/`, and the example config watches that folder with a plain
aging rule: after 7 days the live `sift.log` moves into
`~/Library/Logs/Sift/Archive/` (`onConflict: rename`, so later rotations become
`sift 2.log`, `sift 3.log`, …). The logger reopens the file by path on every
write, so a fresh `sift.log` appears on the next line logged after rotation —
including the `MOVE` line describing the rotation itself.

The log needs its own directory because Sift's rules match on *Date Added*, not
filename: pointing a rule at `~/Library/Logs` would age out every other app's
logs too.

Because every run appends to the log, the log's own directory is never added to
launchd `WatchPaths` — that would wake Sift in a loop. This exclusion is built
in; no config needed.

Archives are never deleted (Sift never deletes anything). At typical volume that
is a few megabytes per month; empty `Archive/` whenever you like, or add a second
rule moving aged archives into a Delete folder.

## Build & install

```bash
swift build -c release
cp .build/release/sift /usr/local/bin/sift
mkdir -p ~/.config/sift
cp sift.example.json ~/.config/sift/sift.json   # then edit to taste
sift install                                    # schedules the launchd agent
```

Log and archive directories are created on demand — nothing to set up.

Image optimization is optional and needs at least one external tool. Either
install them, or install [ImageOptim](https://imageoptim.com) and Sift will
borrow the binaries from its bundle:

```bash
brew install oxipng jpeg-turbo gifsicle   # png, jpeg, gif respectively
```

Without them Sift logs `SKIP no optimizer for <format>` once per run and does
everything else normally.

## Commands

- `sift run [--config <path>] [--dry-run]` — one pass: optimize first, then age.
- `sift status` — show what would be optimized, what would move, and each file's
  countdown. Read-only; never writes bytes or tags.
- `sift install` / `sift uninstall` — manage the launchd agent.

The agent runs on `settings.interval` and, when optimization is enabled, also
whenever something lands in a live folder (launchd `WatchPaths`), so new
screenshots and downloads are handled within seconds.

## Config

See `sift.example.json`. JSON has no comments, so each field is documented here:

- `settings.interval` — how often the agent runs (`30m`, `1h`, `6h`, `1d`).
- `settings.log` — log file path. Keep it in its own directory (the example uses
  `~/Library/Logs/Sift/sift.log`) if you point a rotation rule at it; the log's
  directory is automatically excluded from launchd `WatchPaths`.
- `settings.dryRun` — global no-op toggle (also `--dry-run`).
- `settings.categories` — category → extension list; first match wins, else `Other`.
- `settings.tagging` — `enabled` and the tag text `prefix`.
- `settings.optimize` — optional. `enabled`, `skipTag` (default `Keep OG`), and
  `level` (oxipng effort 0–6, default 2). Omit the block entirely to disable
  optimization.
- `folders[]` — `path`, optional `ignore` (names skipped at the top level), and `rules[]`
  (`match` + `conditions` + `actions`). v1 supports the `date_added` /
  `older_than` condition and the `move` action.
