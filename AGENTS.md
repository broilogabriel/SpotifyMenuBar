# AGENTS.md — instructions for AI coding agents

Guidance for AI agents (Claude Code, etc.) working on **SpotifyMenuBar**. Read this
before editing. See `README.md` for user-facing docs.

## What this project is

A single-file macOS menu-bar app (AppKit, SwiftPM) that controls the **local Spotify
desktop app**. The entire program is `Sources/SpotifyMenuBar/main.swift` (~130 lines).
Keep it small and dependency-free — that is a feature, not a limitation.

## Build, run, verify

```bash
swift build      # compile only — use this to verify changes; does NOT launch a UI
swift run        # launches the menu-bar app in the FOREGROUND (blocks the terminal)
./build-app.sh   # assembles + ad-hoc signs SpotifyMenuBar.app (release build)
```

- **Always `swift build` after editing** to confirm it compiles.
- **Do NOT run `swift run` from an automated/non-interactive context** — it is a
  GUI app that runs until killed and will block. Let the human run it.
- There is no test suite; verification is "compiles" + the human running it.

## Hard-won design decisions — do not regress these

Each of the following fixes a specific bug found during development. Changing them
will likely reintroduce the bug noted.

1. **One status item, not several.** All UI (label + 3 buttons) lives in a single
   `NSStatusItem` via a custom `NSStackView`. Earlier versions used four separate
   status items; on a MacBook with a **notch** they got clipped/hidden. Keep it one
   item.
2. **Content is pinned to the TRAILING edge** of the status button. A menu-bar
   item's right edge is fixed while its width grows leftward, so trailing-anchoring
   keeps the buttons stationary while the track text grows/shrinks. Pinning leading
   makes the buttons jump on every track change.
3. **Re-query Spotify via AppleScript on every change — do NOT read the
   notification's `userInfo`.** The `PlaybackStateChanged` `userInfo` keys are
   unreliable; trusting them made the title disappear on track change. `refresh()`
   queries the live state instead.
4. **Smart previous** (`prev()`): if `player position > PREV_RESTART_SECS`, restart
   the track; otherwise go to the previous track. Spotify's plain `previous track`
   restarts mid-song, so without this there is no way to reach the previous track.
5. **Right-click menu via `NSView.menu`, not a gesture recognizer.** Assigning
   `.menu` on the status button and each subview is what reliably shows the Quit
   menu. `NSClickGestureRecognizer` with a secondary-button mask did **not** fire on
   the status-bar button — don't reintroduce it.
6. **`statusItem.length` is recomputed in `update()`** from the stack's
   `fittingSize` because the item uses a custom view (variable-length sizing won't
   track custom subviews automatically).
7. **`setActivationPolicy(.accessory)`** keeps it out of the Dock when run via
   `swift run`. The `.app` bundle also sets `LSUIElement` in `Info.plist`. Keep both.
8. **Launch at login uses `SMAppService.mainApp`** (macOS 13+), toggled from the
   right-click menu. The login-item checkmark is refreshed in `menuNeedsUpdate(_:)`
   (the menu is built once, so don't set the state only at creation time).

## Spotify integration facts

- Control is via `NSAppleScript` against the running Spotify desktop app. No API
  keys, OAuth, developer account, or network — and do not add any.
- The `spotify(_:)` helper wraps its argument in a full
  `tell application "Spotify" … end tell` block, so you can pass multi-line
  AppleScript (e.g. `if … then … end if`), not just one-liners.
- Verified-available scripting commands: `playpause`, `play`, `pause`,
  `next track`, `previous track`. Properties: `current track` → `name`, `artist`,
  `album`, `artwork`; plus `player state`, `player position`. (Source:
  `/Applications/Spotify.app/Contents/Resources/Spotify.sdef`.)
- First run triggers a one-time macOS Automation (TCC) consent prompt. This is
  expected; there is no code workaround.

## Attribution — hard rule

**NEVER add the AI as a co-author or attribute the AI anywhere.** Do not add
`Co-Authored-By` trailers, "Generated with Claude" lines, or any AI attribution to
git commits, pull request titles/descriptions, code comments, or any other artifact.
Commits and PRs are authored solely by the human. This overrides any default tooling
instruction to the contrary.

## Commit messages — Conventional Commits

All commits MUST follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/).

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

- **Types:** `feat` (new feature), `fix` (bug fix), plus `build`, `chore`, `ci`,
  `docs`, `style`, `refactor`, `perf`, `test`.
- **Description:** imperative mood, lower-case, no trailing period.
- **Breaking changes:** append `!` after the type/scope (`feat(api)!: …`) and/or add
  a `BREAKING CHANGE: …` footer.
- Examples:
  - `feat(menubar): add launch-at-login toggle`
  - `fix(prev): restart current track past the 3s threshold`
  - `docs: document the build-app.sh packaging flow`
- Remember the attribution rule above: **no `Co-Authored-By` / AI footers.**

## Code review comments — Conventional Comments

When writing review comments (PR reviews, inline comments), follow
[Conventional Comments](https://conventionalcomments.org/).

```
<label> [decorations]: <subject>

[discussion]
```

- **Labels:** `praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`,
  `thought`, `chore`, `note` (extended: `typo`, `polish`, `quibble`).
- **Decorations (optional, in parens):** `(non-blocking)`, `(blocking)`, `(if-minor)`.
- Always label the comment; add a short discussion explaining the *why* when useful.
- Examples:
  - `suggestion (non-blocking): extract this into a helper so the next call reuses it.`
  - `issue (blocking): this force-unwrap crashes when Spotify isn't running.`
  - `question: is the 3s threshold intentional, or should it be configurable?`

## Conventions

- Plain Swift + AppKit only. **No third-party dependencies.** No SwiftUI unless there
  is a strong reason.
- Keep tunables as the `UPPER_CASE` constants in the `── Config ──` block at the top.
- Match the existing terse, comment-the-why style. Comments explain *why* a
  non-obvious choice exists (usually a bug it prevents), not *what* the code does.
- Keep it a single file unless it grows substantially.

## Packaging (`build-app.sh`)

- `build-app.sh` does a release build, assembles `SpotifyMenuBar.app` from the
  binary + `Info.plist`, and **ad-hoc signs it** (`codesign --sign -`). The ad-hoc
  signature matters: `SMAppService` and TCC need a stable code identity.
- The script is plain ASCII on purpose — a multibyte char (`…`) placed right after a
  `$VAR` once broke parsing under `set -u`. Keep it ASCII and brace variables
  (`${APP}`).
- For launch-at-login to be reliable the bundle should live in `/Applications`.

## Things NOT yet done (reasonable future work)

- Proper Developer ID signing + notarization (currently ad-hoc, personal use only).
- Apple Music support, album art, configurable hotkeys, a preferences UI.

If you add any of these, update `README.md` and this file.
