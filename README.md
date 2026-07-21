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
