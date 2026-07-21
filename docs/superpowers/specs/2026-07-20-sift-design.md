# Sift — Design Spec

**Date:** 2026-07-20
**Status:** Approved for planning

## 1. Overview

Sift is a small macOS file-automation utility — a self-hosted replacement for the
parts of Hazel we actually use. It ages files out of "live" folders (Desktop,
Downloads) through a two-stage review-then-delete pipeline, sorts them into
category subfolders, and tags them in Finder with a countdown to their next move.

It is macOS-only by nature: it depends on macOS filesystem metadata (Date Added),
Finder tags, and `launchd`. It is written in Swift with **zero third-party
dependencies** (Foundation + Darwin only) and driven by a JSON config file.

## 2. Goals

- Watch `~/Desktop` and `~/Downloads`.
- A file untouched for **7 days** (by macOS *Date Added*) moves into a
  `… to Review` folder, sorted into a category subfolder.
- A file that then sits in `… to Review` for another **7 days** moves into a
  `… to Delete` folder, again sorted by category.
- The `… to Delete` stage is a **holding pen** — Sift never actually deletes.
  The user empties it manually.
- Once Sift has moved a file (Review stage onward), it carries a Finder **tag
  showing days until its next move**, refreshed on each run so it ticks down on
  its own. Files still sitting in the live folders are left untagged.
- All behavior is data-driven from a JSON config; the binary is a generic
  folders → rules → conditions + actions engine.

## 3. Non-Goals

- No real-time watching (FSEvents). Sift runs on a schedule via `launchd`.
- No actual deletion / trashing (may be added later as an optional third stage).
- No cross-platform support.
- No GUI.

## 4. Behavior Specification

### 4.1 The aging pipeline

Per live folder (`Desktop`, `Downloads`), files flow through three locations:

```tsx
~/Desktop                      (live; non-recursive watch)
   │  Date Added > 7 days ago
   ▼
~/Desktop/Desktop to Review/<Category>/   (recursive watch)
   │  Date Added > 7 days ago  (clock reset on entry — see 4.3)
   ▼
~/Desktop/Desktop to Delete/<Category>/   (terminal; not watched)
```

Downloads is identical with `Downloads to Review` / `Downloads to Delete`.

### 4.2 Items and category grouping

Sift ages **whole top-level items** — files, folders, and macOS bundles (`.rtfd`,
`.app`, saved-webpage `_files` folders, …). It **never descends into a directory
or bundle it did not create**, so nested structure is moved intact, never
flattened or shredded.

An item's category is the first category whose extension list (case-insensitive)
contains the item's extension. Items with no recognized extension go to `Other`
if they are files, or `Folders` if they are directories. A directory whose
extension *is* recognized (a bundle like `.rtfd` → Documents, `.app` →
Installers) categorizes by extension like any file. Category folder names are
**capitalized on disk** (`Images/`, `Documents/`, `Folders/`, `Other/`).

Category grouping is applied in **both** the Review and Delete stages.

### 4.3 The clock: macOS Date Added

- "Age" is measured by `ATTR_CMN_ADDEDTIME` (the Finder "Date Added" column),
  read in Swift via `URLResourceValues.addedToDirectoryDate`.
- On **every move**, Sift **stamps the destination's Date Added to now** via
  `setattrlist(ATTR_CMN_ADDEDTIME)`. A raw `rename()` on APFS does not reliably
  reset Date Added, so Sift sets it explicitly. This is what makes the second
  7-day window start cleanly when a file enters `… to Review`.
- Sift is therefore **stateless**: the filesystem's Date Added (which Sift
  controls) is the only state. No database.

### 4.4 Enumeration and loop safety

- Live folders (`Desktop`, `Downloads`) enumerate **top-level items only** and
  list the Review/Delete folders in `ignore`, so a just-moved item is never
  re-swept in the same pass.
- A `… to Review` folder is detected as a **Review stage** because it is itself
  the move destination of another folder. There, Sift's own category subfolders
  (`Images/`, `Folders/`, …) are **transparent**: it descends exactly one level
  into them to age the whole items inside, and no further. A user folder or
  bundle sitting inside a category folder is aged as a single unit.
- `… to Delete` folders are not watched at all.
- Sift never descends into a directory it did not create (any non-category
  folder, or any bundle), guaranteeing whole-item moves.

## 5. Tagging

Sift owns a `Sift` tag namespace and refreshes tags every run. Tagging begins
only once Sift has moved a file — files still in the live folders are untagged,
so every Sift tag signals a file already on its way toward deletion.

| File location | Tag text | Finder color |
|---|---|---|
| Live folder (Desktop/Downloads), waiting | *(untagged)* | — |
| `… to Review`, waiting | `Sift · Nd → Delete` | orange (7) |
| `… to Delete` (terminal) | `Sift · Delete` | red (6) |

### 5.1 Countdown math

For a file under an aging rule with threshold `T` days:

```tsx
elapsed        = now − addedToDirectoryDate
remainingDays  = ceil((T − elapsed) / 1 day)
if remainingDays <= 0 -> the file moves this run
else                  -> tag = "<prefix> · <remainingDays>d → <NextStep>"
```

- `remainingDays` is clamped to ≥ 1 for display (a file with < 1 day left shows
  `1d`; at 0 it moves).
- `NextStep` is the title-cased last word of the move destination's folder name
  (`Desktop to Review` → `Review`), so it needs no extra config.
- The distinct-tag set is bounded (~15 strings), one color per string, keeping
  the Finder tag sidebar clean.

### 5.2 Refresh semantics

Because tags must stay current, each run Sift updates the countdown tag on **every**
file in a watched `… to Review` folder — not only the ones moving. When a move
lands a file in a non-watched (terminal) `… to Delete` destination, Sift writes
the static terminal tag instead of a countdown. Live folders are never tagged.

### 5.3 Color mechanism

Tag **names** are written via `URLResourceValues.tagNames`. To force a specific
color, Sift writes the Finder user-tags xattr directly (the `com.apple.metadata`
domain key `kMDItemUserTags`, underscore-prefixed) as a property-list array of
`"name\n<colorIndex>"` strings (via `PropertyListSerialization`). Finder color
indices used: 7 = orange (Review countdown), 6 = red (terminal Delete).

## 6. Move Semantics

- Same volume: `FileManager.moveItem`. Cross-volume: copy then remove.
- Destination category directory is created on demand (`createDirectory`,
  intermediate dirs allowed).
- `onConflict`:
  - `rename` (default): append ` 2`, ` 3`, … before the extension until unique.
  - `replace`: overwrite the existing file.
  - `skip`: leave the source in place, log, move on.
- After a successful move: stamp Date Added (4.3), then apply the tag (5).
- `dryRun`: compute and log every action; change nothing on disk.

## 7. Configuration (native JSON)

Config is JSON, decoded with `JSONDecoder` into `Codable` structs. Because JSON
has no comments, an annotated `sift.example.json` + README document each field.
Default config path: `~/.config/sift/sift.json` (overridable with `--config`).

### 7.1 Example

```json
{
  "settings": {
    "interval": "1h",
    "log": "~/Library/Logs/sift.log",
    "dryRun": false,
    "categories": {
      "images":     ["jpg","jpeg","png","gif","heic","heif","webp","tiff","tif","bmp","svg","raw","cr2","cr3","nef","arw","dng"],
      "documents":  ["pdf","doc","docx","txt","rtf","md","pages","odt","csv","xls","xlsx","ppt","pptx","key","numbers","epub"],
      "archives":   ["zip","tar","gz","tgz","bz2","xz","rar","7z"],
      "installers": ["dmg","pkg","mpkg","app"],
      "audio":      ["mp3","m4a","aac","wav","flac","aiff","ogg"],
      "video":      ["mp4","mov","m4v","avi","mkv","webm","wmv"],
      "code":       ["js","ts","jsx","tsx","go","py","rb","rs","java","c","h","cpp","sh","json","yaml","yml","html","css","sql"]
    },
    "tagging": { "enabled": true, "prefix": "Sift" }
  },
  "folders": [
    {
      "path": "~/Desktop",
      "recurse": false,
      "filesOnly": true,
      "ignore": ["Desktop to Review", "Desktop to Delete"],
      "rules": [
        {
          "name": "Age stale Desktop files into Review",
          "match": "all",
          "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
          "actions": [ { "move": { "to": "~/Desktop/Desktop to Review", "sortInto": "category", "onConflict": "rename" } } ]
        }
      ]
    },
    {
      "path": "~/Desktop/Desktop to Review",
      "recurse": true,
      "filesOnly": true,
      "rules": [
        {
          "name": "Age stale Review files into Delete",
          "match": "all",
          "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
          "actions": [ { "move": { "to": "~/Desktop/Desktop to Delete", "sortInto": "category", "onConflict": "rename" } } ]
        }
      ]
    },
    {
      "path": "~/Downloads",
      "recurse": false,
      "filesOnly": true,
      "ignore": ["Downloads to Review", "Downloads to Delete"],
      "rules": [
        {
          "name": "Age stale Downloads into Review",
          "match": "all",
          "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
          "actions": [ { "move": { "to": "~/Downloads/Downloads to Review", "sortInto": "category", "onConflict": "rename" } } ]
        }
      ]
    },
    {
      "path": "~/Downloads/Downloads to Review",
      "recurse": true,
      "filesOnly": true,
      "rules": [
        {
          "name": "Age stale Review files into Delete",
          "match": "all",
          "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
          "actions": [ { "move": { "to": "~/Downloads/Downloads to Delete", "sortInto": "category", "onConflict": "rename" } } ]
        }
      ]
    }
  ]
}
```

### 7.2 Field reference

- `settings.interval` — duration string (`30m`, `1h`, `6h`, `1d`); drives the
  launchd `StartInterval`.
- `settings.log` — log file path (`~` expanded).
- `settings.dryRun` — global dry-run toggle (also available as `--dry-run`).
- `settings.categories` — map of category name → lowercase extension list.
  First match wins; unmatched → `Other`.
- `settings.tagging.enabled` / `.prefix` — countdown tagging on/off and the tag
  text prefix.
- `folders[]`:
  - `path` — folder to scan (`~` expanded).
  - `recurse` — descend into subfolders (bool).
  - `filesOnly` — ignore directories (bool).
  - `ignore` — folder/file names (top-level) to skip.
  - `rules[]`:
    - `name` — human label (used in logs).
    - `match` — `all` | `any` over conditions.
    - `conditions[]` — `{ attr, op, value }`. v1 supports `attr: date_added`,
      `op: older_than`, `value: <duration>`. (Vocabulary is intentionally small;
      the engine is structured to grow.)
    - `actions[]` — v1 supports `move: { to, sortInto, onConflict }` where
      `sortInto` ∈ { `category`, `none` } and `onConflict` ∈ { `rename`,
      `replace`, `skip` }.

## 8. Architecture

Swift Package Manager executable `sift`. Zero third-party dependencies —
`Foundation` + `Darwin` only. Small, single-purpose files:

```bash
Package.swift
Sources/sift/
  main.swift          # entry point + hand-rolled arg dispatch
  CLI.swift           # subcommand parsing (run/install/uninstall/status)
  Config.swift        # Codable structs + JSON loading + ~ expansion + validation
  Duration.swift      # parse "7d"/"1h"/"30m" -> TimeInterval
  Category.swift      # extension -> category resolution
  Rules.swift         # condition evaluation (older_than, match all/any)
  Scanner.swift       # enumerate folders, apply rules, orchestrate a run
  Actions.swift       # move (conflict handling, cross-volume), mkdir
  FSMetadata.swift    # Date Added get/set; Finder tag get/set (+ colors)
  Launchd.swift       # write/remove the LaunchAgent plist
  Logger.swift        # timestamped append-only logging
Tests/siftTests/
```

### 8.1 CLI surface

- `sift run [--config <path>] [--dry-run]` — perform one scan pass.
- `sift status [--config <path>]` — print, per folder, what would move next and
  each managed file's current countdown. No changes.
- `sift install [--config <path>]` — write and load the LaunchAgent.
- `sift uninstall` — unload and remove the LaunchAgent.

### 8.2 launchd agent

- Label `com.brandonshutter.sift`.
- Path `~/Library/LaunchAgents/com.brandonshutter.sift.plist`.
- `ProgramArguments`: absolute path to `sift`, `run`, `--config <path>`.
- `StartInterval`: seconds derived from `settings.interval`.
- `StandardOutPath` / `StandardErrorPath`: `settings.log`.
- `RunAtLoad`: true.

## 9. Error Handling & Logging

- Every run appends a timestamped section to `settings.log`: files scanned, each
  action taken (or would-be action under dry-run), and any per-file errors.
- Per-file failures (permission denied, missing during move, xattr failure) are
  logged and skipped — one bad file never aborts the run.
- Config load/validation errors are fatal for `run` and reported clearly (bad
  path, unknown `attr`/`op`/`sortInto`/`onConflict`, unparseable duration).
- Missing destination folders are created; a missing *source* folder is logged
  and skipped.

## 10. Testing Strategy

- **Unit (table) tests:** duration parsing, category resolution (incl. `Other`
  fallback and case-insensitivity), `older_than` evaluation, `match` all/any,
  countdown math (ceil, clamp, move-at-0), conflict renaming.
- **Integration (temp dir, darwin-gated):** create files, backdate Date Added,
  run a scan, assert files land in the right category folder, Date Added is
  re-stamped, and the expected tag/color is written; verify `ignore` and
  `recurse` semantics and that a run is idempotent (no re-sweep).
- **Dry-run test:** assert no filesystem changes while actions are logged.

## 11. Future / Deferred

- Optional third stage: trash items after N days in `… to Delete`.
- More conditions (name/extension/size matchers) and actions (rename, copy, run
  script) as the need arises.
- FSEvents-based real-time mode as an alternative to interval scanning.
