# Sift — Log Rotation Design Spec

**Date:** 2026-08-03
**Status:** Approved for planning

## 1. Overview

Rotate Sift's own log with Sift's own aging rules — dogfooding, no new engine
code. The log moves to a directory Sift exclusively owns, a normal `folders[]`
entry ages it into an `Archive/` subfolder after 7 days, and `Logger`'s
reopen-by-path-per-call behavior means the live log can be rotated mid-run with
no special handling (verified empirically before this spec was written).

```text
~/Library/Logs/Sift/
  sift.log          ← live; the watched folder is Sift/, ignore: ["Archive"]
  Archive/
    sift.log        ← rotated at 7 days
    sift 2.log      ← next rotation (onConflict: rename)
```

## 2. Goals

- Archive the live log after 7 days untouched (`date_added` / `older_than: 7d`),
  via a plain config rule — the engine is not modified.
- The log lives in `~/Library/Logs/Sift/`, a directory only Sift writes to, so
  `date_added` alone is a safe condition. `~/Library/Logs` itself (61 entries
  from other apps on the deployed machine) is never watched.
- The log directory must never appear in launchd `WatchPaths` — watching the
  folder Sift logs into is a guaranteed feedback loop (log write → launchd wake
  → run → log write), bounded only by ThrottleInterval. This is a correctness
  invariant enforced in code, not a config option someone can get wrong.

## 3. Non-Goals

- No second stage and no deletion: archives accumulate (~1.5 MB per two weeks;
  the user said "just move after 7 days"). A Review→Delete chain can be added
  later as pure config.
- No filename-pattern condition in the rule engine. `Config.validate()` stays
  deliberately restrictive; the dedicated directory removes the need.
- No rotation logic inside `Logger` — that would bypass the dogfood premise.
- Not fixed: the run that performs a rotation still holds launchd's stderr fd
  on the archived inode, so a crash during that exact run would write into the
  archive. Every later run opens the new path. Accepted cosmetic wrinkle.

## 4. Behavior

### 4.1 Config (shipped in `sift.example.json`, mirrored on the live machine)

`settings.log` becomes `~/Library/Logs/Sift/sift.log`, and one folder entry is
added:

```json
{
  "path": "~/Library/Logs/Sift",
  "ignore": ["Archive"],
  "rules": [
    { "name": "Rotate sift logs", "match": "all",
      "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
      "actions": [ { "move": { "to": "~/Library/Logs/Sift/Archive",
                               "sortInto": "none", "onConflict": "rename" } } ] }
  ]
}
```

- `sortInto: "none"` keeps the archive flat — with `"category"`, `.log` matches
  no category and would land in `Other/`.
- `ignore: ["Archive"]` is load-bearing: without it Sift treats `Archive` as an
  aged item and moves the folder into itself.
- `onConflict: "rename"` gives `sift 2.log`, `sift 3.log`, … on later rotations.

### 4.2 Expected side effects (accepted, documented)

The log folder is a watched live folder like any other, so with tagging enabled:
- the live `sift.log` carries an orange countdown tag `Sift · Nd → Archive`
  once it is within the tagging window — one xattr write per pass, harmless;
- an archived log carries the red terminal tag `Sift · Archive`.

The rotation `MOVE` line itself lands in the *new* log (Logger reopens by path
on every call). `Logger.log()` recreates the directory and file on the next
write after rotation.

### 4.3 WatchPaths invariant

`watchPaths(for config:)` additionally excludes the parent directory of
`settings.log` (standardized, tilde-expanded). Rationale in §2. This holds for
any config, not just the shipped one — a user pointing `settings.log` into
`~/Desktop` today would already have the loop.

## 5. Code changes

| File | Change |
|---|---|
| `Sources/SiftCore/Launchd.swift` | `watchPaths(for:)` filters out the log's parent directory |
| `sift.example.json` | new log path + rotation folder entry |
| `README.md` | log-rotation section; config docs updated |
| `Tests/SiftCoreTests/LaunchdTests.swift` | exclusion cases |
| `Tests/SiftCoreTests/ScannerTests.swift` | rotation-config regression (flat move, terminal tag, Archive ignored) |

No changes to `Scanner`, `Rules`, `Actions`, `Config`, or `Logger`.

## 6. Deployment (ops, not code)

1. `mkdir -p ~/Library/Logs/Sift/Archive`
2. Move the existing `~/Library/Logs/sift.log` (1.5 MB of history, including
   the 5,592 pre-fix corrupted lines, kept as an artifact) to
   `~/Library/Logs/Sift/Archive/sift.log`.
3. Update `~/.config/sift/sift.json`: new `settings.log` path + the folder
   entry from §4.1 (backup first, as before).
4. Rebuild, install binary, `sift install` — rewrites `StandardOutPath` /
   `StandardErrorPath` and the (now log-free) `WatchPaths`.
5. Verify: plist has no `~/Library/Logs/Sift` in WatchPaths; `sift status`
   shows the archived log as a normal aged item and nothing else in
   `~/Library/Logs` is touched; a fresh run writes to the new path.

## 7. Testing

- `LaunchdTests`: log dir excluded from WatchPaths when it is a configured
  folder; unrelated live folders still watched; log path with `~` expands
  before comparison.
- `ScannerTests`: a stale file in a watched folder with `sortInto: "none"`
  moves flat into the destination (no category subfolder), gets the terminal
  tag, and the destination folder itself is skipped via `ignore`.
- Manual (already done pre-spec, repeated at deploy): the binary rotates its
  own live log mid-run; the MOVE line appears in the new log.
