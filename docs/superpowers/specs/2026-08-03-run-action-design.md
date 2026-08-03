# Sift — Run Action Design Spec

**Date:** 2026-08-03
**Status:** Approved for planning

## 1. Overview

A user-defined shell command as a rule action, borrowing Hazel's `$1` model: the
script text is one argv element, the matched item's path is another, and the two
are never concatenated. This is the first time Sift's config becomes executable
code, and the escape hatch that makes hardcoded rename/notify/copy actions
unnecessary.

Enabling it requires the first real expansion of the action model: `Action`
becomes a sum type (`move` | `run`), and the one-action-per-rule limit is
lifted. One-rule-per-folder stays; that is a separate phase.

```json
"rules": [
  { "name": "Notify then file away", "match": "all",
    "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
    "actions": [
      { "run":  { "command": "osascript -e \"display notification \\\"$1\\\"\"" } },
      { "move": { "to": "~/Desktop/Desktop to Review", "sortInto": "category", "onConflict": "rename" } }
    ] }
]
```

## 2. Decisions already made (with the user)

- **Ungated, crontab trust model.** No enable flag, no executable-only
  restriction. It is the user's config on the user's machine; injection safety
  comes from the argv model, not from gating.
- **Hazel's `$1` convention.** One argument, the item's full path. External
  scripts need no separate mode — `exec ~/bin/thing.sh "$1"` covers them.
- **Actions run in declared order and moves re-thread the path**: `[run, move]`
  scripts the original location, `[move, run]` scripts the new one.
- **Failure stops the chain for that item** (non-zero exit or timeout): log
  `ERROR run`, skip the item's remaining actions, no marker/no event, retried
  next pass. Matches Hazel and the optimize pass's failure direction.

## 3. Config model

```swift
public struct Action: Codable {
    public let move: MoveAction?          // was non-optional
    public let run: RunAction?

    public init(move: MoveAction? = nil, run: RunAction? = nil)
}

public struct RunAction: Codable {
    public let command: String            // required
    public let shell: String              // default "/bin/zsh"
    public let timeout: TimeInterval      // seconds; default 60
}
```

- `RunAction` decodes like `OptimizeSettings`: absent `shell`/`timeout` take
  defaults via a custom `init(from:)`; a memberwise init with the same defaults
  serves tests.
- The explicit `Action` init with defaulted parameters keeps every existing
  `Action(move: …)` fixture compiling unchanged.

### Validation (`Config.validate`)

- Exactly one of `move` / `run` per action — zero or both is a
  `ConfigError.validation`.
- `rule.actions.count <= 1` is **removed**. `folder.rules.count <= 1` stays.
- `run.command` must be non-empty.
- `run.shell` must be an absolute path (leading `/`). Existence is *not*
  checked at validate time — the config may be edited on one machine and run on
  another; a missing shell fails loudly at run time instead.
- `run.timeout` must be in `1...600`.
- Existing `MoveAction` validation applies whenever `move` is present.

## 4. Execution

```swift
runProcess(action.shell, ["-c", action.command, action.shell, path], timeout: action.timeout)
//                              ↑ script text    ↑ $0            ↑ $1
```

- POSIX `sh -c` semantics: the word after the command string becomes `$0`, the
  next becomes `$1`. The path is never interpolated into the script text, so a
  file named `; rm -rf ~` or `$(reboot).png` is inert data.
- stdout/stderr are discarded (existing `runProcess` behavior). A script that
  wants a record writes its own.
- Exit 0 = success. Anything else, or timeout, is failure: `ERROR run <path>:
  exited <status>` (or `timeout`), chain stops for this item.
- Success logs `RUN <path>: <command>` and emits event kind `.run`
  (`path` = item path at execution time, `detail` = command).
- Dry run logs `DRY run <path>: <command>`, executes nothing, emits nothing
  (consistent with every other action).

## 5. Scanner restructure

This is the bulk of the work. Today `Scanner.run()` computes `dest` /
`terminalDest` once per folder from the single move action and **skips the whole
folder** (`guard let move = rule.actions.first?.move else { continue }`) when
there isn't one — under the new model that guard would silently disable any
folder with a run-only rule.

New shape:

- `run()` no longer extracts a move; it passes the rule through. `reviewStage`
  (destination-of-someone) and the `watched` set are unchanged — both already
  derive from *all* move actions via the destinations set.
- `process(item:rule:…)` on match executes `rule.actions` in order, threading
  the current path: a successful move replaces the path for subsequent actions
  (`moveItem` already returns it); `run` leaves it unchanged. Any action
  failure (move error, conflict-skip, run failure) stops the chain.
- Every path a move produces is inserted into `movedThisRun` (double-hop guard
  unchanged in spirit; it only ever tracked move results).
- **Countdown tags**: the tag needs a destination to count toward, which is now
  the rule's **first move action**. A rule with no move produces no countdown
  tag and no terminal tag — there is no stage to name. `tagCountdown` and the
  not-yet-matched branch look up `rule.actions.first(where: { $0.move != nil })`.
- Dry run: each action logs its `DRY` line against the item's current path;
  since dry-run moves don't produce a real destination path, the original path
  is used throughout the chain (documented, not clever).

## 6. Ripple sites (mechanical)

| Site | Change |
|---|---|
| `OptimizePass.candidates` | `rule.actions.map { $0.move.to }` → `compactMap { $0.move?.to }` |
| `Launchd.watchPaths` | same `compactMap` — run-only folders are live folders and stay watched |
| `Report.foldersTable` | render every action: move rows as today; run rows show the command (escaped, truncated to ~60 chars) |
| `Events.EventKind` | add `case run` — old readers already skip undecodable lines |
| `sift.example.json` | **unchanged.** The shipped template must not contain code that executes on someone's machine by default; README documents the feature |

## 7. Documented hazards (not solved)

- **Self-trigger loop**: a script that writes into a watched folder wakes the
  agent via WatchPaths, bounded by `ThrottleInterval 30` but not prevented.
  Hazel's manual carries the same warning; ours goes in the README.
- **Minimal PATH**: scripts inherit launchd's
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Use absolute paths (Hazel's guidance
  verbatim). Deliberately **not** injecting a richer PATH — a script that
  behaves differently under Sift than in a terminal is worse than one that
  fails loudly. (Sift's own tool discovery searches Homebrew explicitly; user
  scripts are the user's contract.)

## 8. Testing

- **Injection is an explicit test**: files named `; touch pwned ;.png`,
  `$(touch pwned).png`, and a backtick variant — assert the script received the
  exact filename in `$1` (script writes `$1` to a scratch file) and that no
  side-effect file appeared.
- Config: sum-type validation matrix (move-only ok, run-only ok, both rejected,
  neither rejected, empty command, relative shell, timeout 0 / 601 rejected);
  defaults decode; existing configs (move-only, single action) still decode.
- Scanner: `[run, move]` order scripts the pre-move path, `[move, run]` the
  post-move path; failing run stops the chain (file not moved, retried next
  pass); run-only rule executes without moving and produces **no countdown or
  terminal tag**; folder with run-only rule is still scanned at all (the old
  guard's regression); double-hop guard still holds with a move present.
- Events/CLI: `.run` event on success, none on failure or dry run; dry run
  executes nothing (assert via absent side-effect file).
- Launchd/Optimize: destinations derive only from move actions (run-only folder
  appears in WatchPaths as a live folder).
- Report: run action rendered, command HTML-escaped (`<script>` in a command
  must not appear raw).

## 9. Files touched

`Config.swift` · `Scanner.swift` · `Events.swift` · `OptimizePass.swift` ·
`Launchd.swift` · `Report.swift` · their test files · `README.md` · `CLAUDE.md`
(action sum type + argv invariant). `sift.example.json` deliberately untouched.
