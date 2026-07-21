# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sift is a zero-dependency macOS file-automation tool (a homegrown Hazel). It ages items
out of `~/Desktop` / `~/Downloads` through a two-stage **Review → Delete** pipeline keyed on
macOS *Date Added*: 7 days untouched → `… to Review/<Category>/`, 7 more days → `… to Delete/<Category>/`.
It never deletes — the user empties Delete folders manually. See `README.md` for user-facing docs.

## Commands

- Build: `swift build` (release: `swift build -c release`)
- Test: `swift test` (full suite, ~1s)
- Format lint (non-mutating): `swift-format lint --strict <files>`
- Shell lint: `shellcheck --severity=warning <files>`
- Single test: `swift test --filter SiftCoreTests.DurationTests`

Formatting uses **Apple's `swift-format`** (`brew install swift-format`) — NOT SwiftLint or the
Nick Lockwood SwiftFormat. There is no config file, so it runs on built-in defaults with `--strict`
(warnings are errors). Match existing style: 4-space indent, `public` API on SiftCore types.

## Repo setup

`.envrc` (direnv) sets `core.hooksPath=.githooks` and switches the `gh` account to `milehighideas`.
Run `direnv allow` once — the shared pre-commit hook only activates through this. The hook runs
`swift build` + `swift test` when Swift/`Package.resolved` is staged, `swift-format lint --strict`
on staged Swift files, and `shellcheck` on shell scripts. Override with `git commit --no-verify`.

Swift 5.9, macOS 12+, zero external dependencies. Targets: `SiftCore` (lib), `sift` (executable), `SiftCoreTests`.

## Config

JSON at `~/.config/sift/sift.json` (`sift.example.json` is the template). JSON has no comments —
document fields in the README, not inline. `Config.validate()` is deliberately restrictive in v1:
**one rule per folder, one action per rule**; only `attr: date_added` + `op: older_than`; `sortInto`
∈ {`category`,`none`}; `onConflict` ∈ {`rename`,`replace`,`skip`}. Durations are `<n><s|m|h|d>` (e.g. `7d`).
`ExampleConfigTests` asserts the shipped example passes validation — **update the example and this test together**.

## Invariants — do not break these

- **Whole-item moves only.** Files, folders, and bundles (`.rtfd`, `.app`, …) move intact. Sift never
  descends into a folder/bundle it did not create (Review-stage folders are the one exception, descending
  exactly one level into its own category subfolders). Never flatten or recurse into user content.
- **Double-hop guard** (`Scanner`): an item moved once this run is tracked in `movedThisRun`; a second
  matching move is skipped so nothing cascades Review→Delete in a single pass.
- **Clamped elapsed age** (`Rules.remainingDays`): elapsed is `max(0, now - dateAdded)` (guards clock skew);
  the countdown never goes negative and reports 0 only when the item should move now.
- **Date-Added restamp**: after moving, `setDateAdded(..., to: now)` resets the item so the next stage's
  countdown starts fresh (raw `setattrlist`/`ATTR_CMN_ADDEDTIME`).
- **Finder tags** live in the user-tags xattr (`com.apple.metadata` domain); `setSiftTag` strips only its own
  `<prefix> · ` tags before rewriting, preserving user tags (color 6 = red/Delete, 7 = orange/Review).

## Module map (`Sources/SiftCore/`)

`CLI` (arg parse/dispatch) · `Config` (load + `validate`) · `Scanner` (the pass, move orchestration,
double-hop guard) · `Rules` (matching, `remainingDays`) · `Actions` (move + conflict handling) ·
`Category` (extension → category) · `Duration` (parse) · `FSMetadata` (Date Added, Finder tags) ·
`Launchd` (agent `com.brandonshutter.sift`, install/uninstall) · `Logger`. One test file per source file.
