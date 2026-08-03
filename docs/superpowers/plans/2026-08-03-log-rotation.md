# Log Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sift rotates its own log via its own aging rules — a plain config entry ages `~/Library/Logs/Sift/sift.log` into `Archive/` after 7 days.

**Architecture:** No engine changes. The log moves to a directory only Sift owns, one `folders[]` entry does the rotation, and `Logger`'s reopen-by-path-per-call behavior makes rotating the live log safe (verified before the spec was written). The single code change is a correctness invariant: `watchPaths(for:)` must never emit the log's own directory, or launchd loops (log write → wake → run → log write, bounded only by ThrottleInterval 30).

**Tech Stack:** Swift 5.9, Foundation only. No new files.

**Spec:** `docs/superpowers/specs/2026-08-03-log-rotation-design.md` — read it first.

## Global Constraints

- Zero SwiftPM dependencies; no engine changes (`Scanner`, `Rules`, `Actions`, `Config`, `Logger` untouched).
- `swift-format format -i -r Sources Tests` before every commit; the pre-commit hook runs build + tests + `lint --strict`.
- `sift.example.json` and `ExampleConfigTests` must stay in sync (the test loads the shipped example).
- Rotation rule values, verbatim from the spec: `older_than: 7d`, `sortInto: "none"`, `onConflict: "rename"`, `ignore: ["Archive"]`.
- Task 4 (deployment) touches the live machine — get the user's explicit go-ahead before executing it.

---

### Task 1: `watchPaths(for:)` excludes the log's directory

**Files:**
- Modify: `Sources/SiftCore/Launchd.swift` (`watchPaths(for:)`, currently ~lines 7-20)
- Test: `Tests/SiftCoreTests/LaunchdTests.swift`

**Interfaces:**
- Consumes: existing `standardizePath(_:)` (Config.swift), `Settings.log`.
- Produces: same signature `public func watchPaths(for config: Config) -> [String]`; new behavior — the standardized parent directory of `config.settings.log` is filtered out along with move destinations.

- [ ] **Step 1: Write the failing tests**

Append to `LaunchdTests.swift` (inside the class). Note the existing
`testWatchPathsAreLiveFoldersOnly` builds its config inline; these do the same
with a small helper to avoid triplicating the fixture:

```swift
    private func watchConfig(log: String, folders: [FolderConfig]) -> Config {
        let settings = Settings(
            interval: "1h", log: log, dryRun: false, categories: [:],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        return Config(settings: settings, folders: folders)
    }

    private func folder(_ path: String, to destination: String) -> FolderConfig {
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        return FolderConfig(
            path: path, ignore: nil,
            rules: [
                Rule(
                    name: "r-\(path)", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: destination, sortInto: "none", onConflict: "rename"))
                    ])
            ])
    }

    func testWatchPathsExcludesLogDirectory() {
        // The log folder is a watched live folder (the rotation rule), but
        // watching it would loop: log write -> launchd wake -> run -> log write.
        let config = watchConfig(
            log: "/Users/x/Library/Logs/Sift/sift.log",
            folders: [
                folder("/Users/x/Desktop", to: "/Users/x/Desktop/Desktop to Review"),
                folder("/Users/x/Library/Logs/Sift", to: "/Users/x/Library/Logs/Sift/Archive"),
            ])
        XCTAssertEqual(watchPaths(for: config), ["/Users/x/Desktop"])
    }

    func testWatchPathsExcludesLogDirectoryWithTilde() {
        // settings.log usually carries a tilde; comparison must expand it.
        let home = NSHomeDirectory()
        let config = watchConfig(
            log: "~/Library/Logs/Sift/sift.log",
            folders: [
                folder("\(home)/Desktop", to: "\(home)/Desktop/Desktop to Review"),
                folder("~/Library/Logs/Sift", to: "~/Library/Logs/Sift/Archive"),
            ])
        XCTAssertEqual(watchPaths(for: config), ["\(home)/Desktop"])
    }

    func testWatchPathsUnaffectedWhenLogLivesElsewhere() {
        let config = watchConfig(
            log: "/tmp/sift.log",
            folders: [folder("/Users/x/Desktop", to: "/Users/x/Desktop/Desktop to Review")])
        XCTAssertEqual(watchPaths(for: config), ["/Users/x/Desktop"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SiftCoreTests.LaunchdTests`
Expected: `testWatchPathsExcludesLogDirectory` and the tilde variant FAIL — the
log folder is currently included (it is not a move destination). The
`UnaffectedWhenLogLivesElsewhere` case may already pass; that is fine.

- [ ] **Step 3: Implement**

In `Launchd.swift`, replace the body of `watchPaths(for:)`:

```swift
/// The folders launchd should watch so a new arrival is handled within seconds
/// instead of at the next interval: configured folders that are not themselves
/// move destinations — and never the directory the log lives in. Watching the
/// log's own folder is a guaranteed feedback loop (every run appends to the
/// log, which wakes launchd, which runs Sift, which appends to the log),
/// bounded only by ThrottleInterval. This is an invariant, not a config knob.
public func watchPaths(for config: Config) -> [String] {
    let destinations = Set(
        config.folders.flatMap { folder in
            folder.rules.flatMap { rule in
                rule.actions.map { standardizePath($0.move.to) }
            }
        })
    let logDir = (standardizePath(config.settings.log) as NSString).deletingLastPathComponent
    return config.folders.map { standardizePath($0.path) }
        .filter { !destinations.contains($0) && $0 != logDir }
}
```

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all PASS (135 existing + 3 new; the existing WatchPaths tests use
`log: "/tmp/l"`, whose parent `/tmp` is not a configured folder, so they are
unaffected).

- [ ] **Step 5: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Sources/SiftCore/Launchd.swift Tests/SiftCoreTests/LaunchdTests.swift
git commit -m "fix(launchd): never watch the log's own directory

Watching the folder Sift logs into is a feedback loop: every run appends
to the log, which wakes launchd, which runs Sift again, bounded only by
ThrottleInterval. Enforced in watchPaths(for:) as an invariant rather
than a config option someone could get wrong."
```

---

### Task 2: Scanner regression for the rotation config

Locks the config-only behavior the feature depends on: a stale file in a watched
folder with `sortInto: "none"` moves *flat* into the destination (never into a
category subfolder), gets the terminal tag, and the `Archive` destination is
skipped via `ignore` rather than aged as an item.

**Files:**
- Test: `Tests/SiftCoreTests/ScannerTests.swift` (append; no source changes)

**Interfaces:**
- Consumes: existing `Scanner`, `Settings` (with `optimize:` parameter from the
  optimize feature), `setDateAdded`, `rawTags`.
- Produces: nothing — regression coverage only.

- [ ] **Step 1: Write the test**

Append to `ScannerTests.swift`. Do not hard-code the renamed filename of a
second rotation — the conflict-rename format belongs to `Actions`; assert on
the archive's file count instead:

```swift
    // MARK: - Log rotation config (dogfood)

    /// The shipped log-rotation entry is pure config; this locks the engine
    /// behavior it relies on: flat move (sortInto none), terminal tag, the
    /// Archive destination ignored as an item, and rename-on-conflict for the
    /// second rotation.
    func testLogRotationConfigMovesOldLogFlatIntoArchive() throws {
        let logs = home.appendingPathComponent("Logs")
        let archive = logs.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try setDateAdded(archive.path, to: Date().addingTimeInterval(-30 * 86400))
        let cond = Condition(attr: "date_added", op: "older_than", value: "7d")
        let rotation = FolderConfig(
            path: logs.path, ignore: ["Archive"],
            rules: [
                Rule(
                    name: "rotate", match: "all", conditions: [cond],
                    actions: [
                        Action(
                            move: MoveAction(
                                to: archive.path, sortInto: "none", onConflict: "rename"))
                    ])
            ])
        let settings = Settings(
            interval: "1h", log: logs.appendingPathComponent("sift.log").path,
            dryRun: false, categories: ["images": ["png"]],
            tagging: Tagging(enabled: true, prefix: "Sift"), optimize: nil)
        let cfg = Config(settings: settings, folders: [rotation])

        let live = logs.appendingPathComponent("sift.log")
        try "old log content".write(to: live, atomically: true, encoding: .utf8)
        try setDateAdded(live.path, to: Date().addingTimeInterval(-10 * 86400))

        Scanner(config: cfg, now: Date(), dryRun: false, log: { _ in }).run()

        // Rotated: gone from the live path, flat in Archive (not Other/).
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        let archived = archive.appendingPathComponent("sift.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: archive.appendingPathComponent("Other/sift.log").path))
        // Terminal tag, and the Archive folder was not aged into itself.
        XCTAssertTrue(rawTags(of: archived.path).contains { $0.hasPrefix("Sift · Archive") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // A second rotation renames rather than replacing.
        try "newer log content".write(to: live, atomically: true, encoding: .utf8)
        try setDateAdded(live.path, to: Date().addingTimeInterval(-10 * 86400))
        Scanner(config: cfg, now: Date(), dryRun: false, log: { _ in }).run()
        let archivedFiles = try FileManager.default.contentsOfDirectory(atPath: archive.path)
        XCTAssertEqual(archivedFiles.count, 2)
        XCTAssertEqual(
            try String(contentsOf: archived, encoding: .utf8), "old log content")
    }
```

- [ ] **Step 2: Run it**

Run: `swift test --filter SiftCoreTests.ScannerTests/testLogRotationConfigMovesOldLogFlatIntoArchive`
Expected: PASS immediately — this is a regression lock on existing engine
behavior, not new code. If it FAILS, stop: the spec's config assumptions are
wrong and the failure mode matters more than the plan (most likely suspects:
`sortInto: "none"` landing in a category folder, or `ignore` not honored).

- [ ] **Step 3: Format and commit**

```bash
swift-format format -i -r Sources Tests
git add Tests/SiftCoreTests/ScannerTests.swift
git commit -m "test(scanner): lock the engine behavior the log-rotation config relies on"
```

---

### Task 3: Example config + README

**Files:**
- Modify: `sift.example.json` (settings.log + new folder entry)
- Modify: `README.md` (new section + config field notes)
- Test: `Tests/SiftCoreTests/ExampleConfigTests.swift` (existing test must pass; add one assertion)

**Interfaces:**
- Consumes: nothing new.
- Produces: the shipped example demonstrates rotation; docs describe it.

- [ ] **Step 1: Update `sift.example.json`**

Change the log line inside `"settings"`:

```json
    "log": "~/Library/Logs/Sift/sift.log",
```

Append a third entry to the `"folders"` array (after the Downloads Review
folder entry, before the closing `]`):

```json
    {
      "path": "~/Library/Logs/Sift",
      "ignore": ["Archive"],
      "rules": [
        { "name": "Rotate sift logs", "match": "all",
          "conditions": [ { "attr": "date_added", "op": "older_than", "value": "7d" } ],
          "actions": [ { "move": { "to": "~/Library/Logs/Sift/Archive", "sortInto": "none", "onConflict": "rename" } } ] }
      ]
    }
```

- [ ] **Step 2: Extend `ExampleConfigTests`**

Open `Tests/SiftCoreTests/ExampleConfigTests.swift` and read the existing test
to find how it loads the example (it resolves the repo-relative path and calls
`loadConfig`). Add one assertion to the existing test method (or a sibling
method following the same load pattern):

```swift
        // The shipped example dogfoods log rotation: the log folder is watched,
        // and the log's own directory never appears in WatchPaths (loop guard).
        let rotation = config.folders.first { $0.path.hasSuffix("Logs/Sift") }
        XCTAssertNotNil(rotation)
        XCTAssertEqual(rotation?.ignore, ["Archive"])
        XCTAssertFalse(
            watchPaths(for: config).contains { $0.hasSuffix("Logs/Sift") })
```

(`config` here is whatever the existing test names its loaded value — match it.)

- [ ] **Step 3: Run the suite**

Run: `swift test`
Expected: all PASS, including `ExampleConfigTests` against the updated example.

- [ ] **Step 4: Update `README.md`**

Insert after the "Optimizing images" section, before "## Build & install":

```markdown
## Log rotation (dogfood)

Sift rotates its own log with its own rules. The log lives in
`~/Library/Logs/Sift/`, and the example config watches that folder with a plain
aging rule: after 7 days the live `sift.log` moves into
`~/Library/Logs/Sift/Archive/` (`onConflict: rename`, so later rotations become
`sift 2.log`, `sift 3.log`, …). The logger reopens the file by path on every
write, so a fresh `sift.log` appears on the next line logged after rotation —
including the `MOVE` line describing the rotation itself.

Because every run appends to the log, the log's own directory is never added to
launchd `WatchPaths` — that would wake Sift in a loop. This exclusion is built
in; no config needed.

Archives are never deleted (Sift never deletes anything). At typical volume
that is a few megabytes per month; empty `Archive/` whenever you like, or add a
second rule moving aged archives into a Delete folder.
```

In the config field list, extend the `settings.log` line:

```markdown
- `settings.log` — log file path. Keep it in its own directory (the example
  uses `~/Library/Logs/Sift/sift.log`) if you point a rotation rule at it; the
  log's directory is automatically excluded from launchd `WatchPaths`.
```

(Replace the existing `settings.log` bullet — check its current wording first
with `grep -n "settings.log" README.md`.)

- [ ] **Step 5: Format, run everything, commit**

```bash
swift-format format -i -r Sources Tests
swift test
swift-format lint --strict -r Sources Tests
git add sift.example.json Tests/SiftCoreTests/ExampleConfigTests.swift README.md
git commit -m "feat(config): dogfood log rotation in the shipped example

The example watches ~/Library/Logs/Sift and ages the live log into
Archive/ after 7 days — the same rules that age the Desktop."
```

---

### Task 4: Deploy to the live machine — CONFIRM WITH USER FIRST

Ops, not code. This edits the live config, moves the production log, and
reloads the agent. Do not run without the user's explicit go-ahead in this
session (matching how the optimize feature was deployed).

- [ ] **Step 1: Back up and restructure**

```bash
cp ~/.config/sift/sift.json ~/.config/sift/sift.json.bak-$(date +%Y%m%d-%H%M%S)
mkdir -p ~/Library/Logs/Sift/Archive
mv ~/Library/Logs/sift.log ~/Library/Logs/Sift/Archive/sift.log
```

(The 1.5 MB history, including the 5,592 pre-logger-fix corrupted lines, is
kept as an artifact per the spec.)

- [ ] **Step 2: Update the live config**

In `~/.config/sift/sift.json`: change `"log"` to
`"~/Library/Logs/Sift/sift.log"` and append the same folder entry added to
`sift.example.json` in Task 3 (identical JSON, tilde paths).

- [ ] **Step 3: Build, install, re-register**

```bash
swift build -c release
cp .build/release/sift ~/.local/bin/sift
~/.local/bin/sift install
```

- [ ] **Step 4: Verify**

```bash
# WatchPaths must contain Desktop + Downloads and NOT Logs/Sift:
plutil -p ~/Library/LaunchAgents/com.brandonshutter.sift.plist | grep -A4 WatchPaths
# StandardOutPath/StandardErrorPath point at the new log path:
plutil -p ~/Library/LaunchAgents/com.brandonshutter.sift.plist | grep StandardOut
# The archived history is treated as a normal aged item (dry-run only):
~/.local/bin/sift status | grep -i "Logs/Sift" || echo "(archived log not due yet — expected: its Date Added is fresh from the mv)"
# Nothing else in ~/Library/Logs is ever mentioned:
~/.local/bin/sift status | grep -v "Logs/Sift" | grep -c "Library/Logs" # expect 0
# A fresh run writes to the new path:
launchctl kickstart gui/$(id -u)/com.brandonshutter.sift 2>/dev/null || true
sleep 5; tail -3 ~/Library/Logs/Sift/sift.log
```

Note: the `mv` in Step 1 restamps the archived file's Date Added to now, so it
will sit in `Archive/` untouched — correct, since `Archive` is in `ignore` and
never scanned anyway. The *live* log's 7-day clock starts when `Logger` creates
the new file on the first post-deploy write.

---

## Self-review notes

- **Spec coverage:** §4.3 WatchPaths invariant → Task 1; §4.1 config + §4.2
  side effects → Tasks 2–3 (terminal-tag expectation asserted in Task 2; the
  countdown tag on the live log is inherent engine behavior, already covered by
  existing countdown tests); §5 file table → Tasks 1–3; §6 deployment → Task 4;
  §7 testing map → Tasks 1–3 as listed.
- **Type consistency:** only `watchPaths(for:) -> [String]` changes behavior;
  its signature is unchanged and all call sites (installAgent, tests) compile
  as-is. `Settings(interval:log:dryRun:categories:tagging:optimize:)` matches
  the post-optimize-feature shape.
- **Judgment calls encoded:** second-rotation assertion is count-based, not
  filename-based (rename format belongs to Actions); Task 2 is expected to pass
  immediately and doubles as a spec-assumption check; Task 4 is explicitly
  gated on user confirmation.
