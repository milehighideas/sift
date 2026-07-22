---
name: release
description: Build, test, and install a release of sift locally — compile release, run the full suite, copy the binary to the install prefix, and re-register the launchd agent from the installed path. Use when the user asks to cut, build, deploy, or reinstall a sift release.
disable-model-invocation: true
---

# Release sift

Builds an optimized binary and installs it as the running launchd agent. This is a
side-effecting workflow: it overwrites the installed binary and reloads the launchd
agent. Run only when the user asks for a release.

**Install prefix:** default `/usr/local/bin`. If `$ARGUMENTS` names a directory, use it
as the prefix instead (e.g. `/release ~/bin`).

## The one gotcha that dictates the order

`sift install` records the path of the **currently-running** binary
(`CommandLine.arguments[0]`, symlinks resolved) into the launchd plist. So you must
copy the binary to its final location **first**, then invoke `install` from that
installed copy — never from `.build/release/sift`, or the agent will point back at the
build directory and break on the next `swift build`.

## Steps

1. **Preflight.** Confirm a clean-ish tree and that the formatter/tests will pass — the
   release must ship what's committed:
   ```bash
   git status --short
   swift-format lint --strict --recursive Sources Tests
   ```
   If lint reports anything, run `swift-format format -i -r Sources Tests`, show the
   diff, and stop for the user to review before continuing.

2. **Build release + test.**
   ```bash
   swift build -c release
   swift test
   ```
   Both must succeed. Report failures verbatim and stop — never install a failing build.

3. **Copy the binary to the prefix.** Let `PREFIX` be the install prefix from above.
   ```bash
   cp .build/release/sift "$PREFIX/sift"
   ```
   If this fails with permission denied, retry with `sudo cp …` and tell the user you're
   using sudo for the privileged path.

4. **Register/refresh the launchd agent from the installed binary.** Run `install`
   through the copy you just placed, not the build artifact:
   ```bash
   "$PREFIX/sift" install
   ```
   This rewrites `~/Library/LaunchAgents/com.brandonshutter.sift.plist` (pointing at
   `$PREFIX/sift`) and does `launchctl unload` + `load`. Requires a valid config at
   `~/.config/sift/sift.json` — if missing, `install` fails; point the user at
   `sift.example.json` (copy it to `~/.config/sift/sift.json` first).

5. **Verify.**
   ```bash
   "$PREFIX/sift" status            # exercises the installed binary + config
   launchctl list | grep com.brandonshutter.sift
   grep -A1 ProgramArguments ~/Library/LaunchAgents/com.brandonshutter.sift.plist
   ```
   Confirm the plist's first `ProgramArguments` entry is `$PREFIX/sift` (the stable
   path), not a `.build/...` path. Report the installed path and that the agent is
   loaded.

## Notes

- sift has no version string; "release" here means "build optimized and install." Don't
  invent a version tag unless the user asks to tag one.
- To roll back, the user re-runs this skill from an older commit, or `sift uninstall`
  removes the agent (leaving the binary).
