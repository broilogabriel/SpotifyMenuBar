# AGENTS.md — instructions for AI coding agents

Guidance for AI agents (Claude Code, etc.) working on **SpotifyMenuBar**. Read this
before editing. See `README.md` for user-facing docs.

## What this project is

A macOS menu-bar app (AppKit, SwiftPM) that controls the **local Spotify desktop
app**. The AppKit app is one file, `Sources/SpotifyMenuBar/main.swift`; pure logic
(`Config`, `Settings`, `trunc`, `Rung`, `DisplayMode`, `BarLayout`) lives in the
`SpotifyMenuBarCore` library target so it can be exercised by the test runner. Keep it
small and dependency-free — that is a feature, not a limitation.

## Build, run, verify

```bash
swift build      # compile only — use this to verify changes; does NOT launch a UI
swift run        # launches the menu-bar app in the FOREGROUND (blocks the terminal)
./build-app.sh   # assembles + ad-hoc signs SpotifyMenuBar.app (release build)
```

- **Always `swift build` after editing** to confirm it compiles.
- **Do NOT run `swift run` from an automated/non-interactive context** — it is a
  GUI app that runs until killed and will block. Let the human run it.
- **`swift run SpotifyMenuBarCoreTests`** runs the checks for `SpotifyMenuBarCore`
  (exit 0 = pass). This is safe non-interactively — it exits on its own, unlike
  `swift run`, which launches the blocking GUI app.
- There is no `XCTest`/`swift-testing` and **`swift test` does not work**: this machine
  has no Xcode, and the Command Line Tools toolchain ships neither module. That is why
  the tests are a plain executable with a small `expect`/`summarize` harness.

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
6. **`statusItem.length` is recomputed in `resize(to:)`** (called from `apply()`) from
   the stack's `fittingSize` because the item uses a custom view (variable-length
   sizing won't track custom subviews automatically).
7. **`setActivationPolicy(.accessory)`** keeps it out of the Dock when run via
   `swift run`. The `.app` bundle also sets `LSUIElement` in `Info.plist`. Keep both.
8. **Launch at login uses `SMAppService.mainApp`** (macOS 13+), toggled from the
   right-click menu. The login-item checkmark is refreshed in `menuNeedsUpdate(_:)`
   (the menu is built once, so don't set the state only at creation time).
9. **AppleScript runs off the main thread** on `SpotifyClient`'s dedicated serial
   queue (NSAppleScript is not thread-safe); completions hop back to main. Keeping it
   synchronous on main froze the UI during Apple Events round-trips.
10. **Running-check via `NSWorkspace`, never `tell application`.** Detect whether
    Spotify is up with `NSWorkspace.runningApplications` (bundle id
    `com.spotify.client`). A `tell application "Spotify"` query can auto-launch
    Spotify just to read state — `NSWorkspace` doesn't.
11. **`PlaybackStateChanged` is debounced (~100 ms).** Spotify fires several
    notifications per change; coalescing avoids redundant AppleScript queries.
12. **Icon buttons carry VoiceOver labels** (`accessibilityDescription`): "Previous",
    "Play or pause", "Next". The label field is already readable.
13. **`Settings.current()` clamps UserDefaults values** (`maxTrack`/`maxArtist` ≥ 1,
    `prevRestartSecs` ≥ 0) so a bad `defaults write` can't break layout.
14. **Never request more width than the budget allows.** The ceiling is computed in
    `BarLayout.budget` (a fraction, `maxWidthFraction` default 0.25, of the status-item
    region) and enforced by `resolve`'s guards; `resize(to:)` only clamps
    `statusItem.length` to the chosen resolution's own `totalWidth`, which catches a
    label/model width disagreement and nothing more. Before this, `length` came
    straight from `fittingSize`, and a long track title could claim ~45% of the region
    on a notched display — macOS responds by *hiding* items, so the item took its
    neighbours down with it. `BarLayout.pin` (used by the right-click **Display**
    submenu) is a deliberate exception: it overrides the *budget*, on purpose — the
    user is trading the safety margin for their stated preference, and clamping a pin
    to the same 0.25 budget would make it meaningless, since `resolve` would already
    have picked that rung if it fit. Its only ceiling is the region itself (100% of
    it), which exists to stop an absurd `maxTrack`/`maxArtist` override from running
    away, **not** to guarantee the item stays visible. A pinned larger rung on a
    crowded bar *can* still get hidden by macOS; the remedy is the user's — pick a
    smaller rung, or Auto.
15. **Never add a rung below `playPause`, and never let the ladder bottom out to
    nothing.** `playPause` is the floor — the item must always render something. If a
    narrower rung is ever needed, its dropped controls must relocate into the
    right-click menu the same way `playPause` moves prev/next there, or that
    function becomes unreachable.
16. **Clip detection is NOT implemented, on purpose.** macOS exposes no API for
    remaining menu-bar space, and which observable field changes when it clips a status
    item is undocumented. The shipped behavior is the computed ceiling alone, which the
    design sanctions as a complete outcome. `debugLayout` is the instrumentation for
    measuring it; the probe and the design for the corrective feedback loop live in
    `docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md`. If it is ever
    built, `clipVerdict` must stay **three-state** — `.unknown` means "no usable signal",
    and the caller then trusts the budget alone — and must compare the granted window
    width against `statusItem.length`, never against `Resolution.totalWidth`, which
    `resize(to:)` deliberately sets a few points below at labelled rungs.
17. **`BarLayout.labelText(for:track:artist:settings:)` is the ONLY place a bar label
    string is composed.** `resolve` and `pin` both route through it. An empty artist
    (Spotify ads, untagged local files) must collapse to the track alone — a stranded
    `"Track – "` shipped twice because a second composer existed. Do not add a third.
18. **Tooltip and `accessibilityLabel` carry the full title on the host button**, not
    only on the label, because at `icons` and `playPause` the label is hidden and they
    become the only way to know what is playing. Setting them on the label alone
    silently breaks decision #12 at reduced rungs.

## Spotify integration facts

- Control is via `NSAppleScript` against the running Spotify desktop app. No API
  keys, OAuth, developer account, or network — and do not add any.
- `SpotifyClient.run(_:then:)` wraps its argument in a full
  `tell application "Spotify" … end tell` block (built in `SpotifyClient.execute`),
  so you can pass multi-line AppleScript (e.g. `if … then … end if`), not just
  one-liners. It runs on a private serial queue and delivers the result on main.
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
- Tunables live in the `Config` caseless enum (lowerCamelCase, Swift-idiomatic).
  Runtime overrides are read from `UserDefaults` via `Settings.current()`.
- Match the existing terse, comment-the-why style. Comments explain *why* a
  non-obvious choice exists (usually a bug it prevents), not *what* the code does.
- The AppKit app is one file (`Sources/SpotifyMenuBar/main.swift`). Pure logic lives in
  `Sources/SpotifyMenuBarCore/` so it can be exercised by the test runner — the split
  exists for that reason alone, so don't move AppKit code there. **`SpotifyMenuBarCore`
  must never `import AppKit`.**

## Design docs (`docs/superpowers/`)

Specs and implementation plans produced by the superpowers skills live here and are
**versioned — tracked in git and committed** alongside the code they describe. They are
the record of why a change looks the way it does; a design that only exists in a
transcript is lost.

- Specs → `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- Plans → `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`

**Do not add a `.gitignore` under `docs/superpowers/`.** Some global agent configs default
to making these artifacts local-only; that default does not apply to this repo. If you find
one there, it is a mistake — remove it rather than working around it. When a skill says to
commit the spec, do it for real.

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
- The clip-detection / auto-demotion feedback loop described in decision #16 —
  intentionally not implemented; it needs human-gathered probe data first. See
  `docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md`.

If you add any of these, update `README.md` and this file.
