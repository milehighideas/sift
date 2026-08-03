# Sift

A tiny, zero-dependency macOS file-automation tool. Ages items out of Desktop and
Downloads through a two-stage review→delete pipeline, sorts them into category
subfolders, and tags them in Finder with a countdown.

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

## Build & install

```bash
swift build -c release
cp .build/release/sift /usr/local/bin/sift
mkdir -p ~/.config/sift
cp sift.example.json ~/.config/sift/sift.json   # then edit to taste
sift install                                    # schedules the launchd agent
```

## Commands

- `sift run [--config <path>] [--dry-run]` — one pass.
- `sift status` — show what would move and each file's countdown; no changes.
- `sift install` / `sift uninstall` — manage the launchd agent.

## Config

See `sift.example.json`. JSON has no comments, so each field is documented here:

- `settings.interval` — how often the agent runs (`30m`, `1h`, `6h`, `1d`).
- `settings.log` — log file path.
- `settings.dryRun` — global no-op toggle (also `--dry-run`).
- `settings.categories` — category → extension list; first match wins, else `Other`.
- `settings.tagging` — `enabled` and the tag text `prefix`.
- `folders[]` — `path`, optional `ignore` (names skipped at the top level), and `rules[]`
  (`match` + `conditions` + `actions`). v1 supports the `date_added` /
  `older_than` condition and the `move` action.
