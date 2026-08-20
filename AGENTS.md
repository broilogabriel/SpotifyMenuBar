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
    smaller rung, or Auto. The fraction is now the *softer* of two ceilings: measured
    free space (decision #19) is the harder one, and the automatic path takes whichever
    is smaller.
15. **Never add a rung below `playPause`, and never let the ladder bottom out to
    nothing.** `playPause` is the floor — the item must always render something. If a
    narrower rung is ever needed, its dropped controls must relocate into the
    right-click menu the same way `playPause` moves prev/next there, or that
    function becomes unreachable.
16. **Clip detection was probed on 2026-08-19 and abandoned — do not reopen it without
    reading why.** The shipped behavior is the computed ceiling alone, and that is final,
    not pending. The probe showed the design targeted the wrong failure mode: with the bar
    crowded, our item asked for 188.5pt (24% of a 772pt region), was granted it, and stayed
    `visible=Y` — while a *neighbouring* icon got evicted. All three candidate predicates
    (`isVisible`, granted width vs requested, `minX` vs region) correctly reported healthy,
    because we were not the clipped party; we were the cause. Watching our own window can
    never detect that. Worse, being modest did not prevent it: macOS offers no way to ask
    how much room remains before claiming some. `clipVerdict`, `applyWithFeedback` and
    `Clip` were never written. Full measurements in
    `docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md` section 5.
    Two facts that cost time to learn: **`NSLog` is unusable for diagnostics** here —
    current macOS redacts its formatted string to `<private>` in the unified log, so
    `logLayout` uses `os.Logger` with an explicit `privacy: .public` per value; and
    **`maxWidthFraction -float 1.0` cannot force clipping**, because label length is
    bounded by real track metadata, not config.
17. **`BarLayout.labelText(for:track:artist:settings:)` is the ONLY place a bar label
    string is composed.** `resolve` and `pin` both route through it. An empty artist
    (Spotify ads, untagged local files) must collapse to the track alone — a stranded
    `"Track – "` shipped twice because a second composer existed. Do not add a third.
18. **Tooltip and `accessibilityLabel` carry the full title on the host button**, not
    only on the label, because at `icons` and `playPause` the label is hidden and they
    become the only way to know what is playing. Setting them on the label alone
    silently breaks decision #12 at reduced rungs.
19. **The automatic path must never exceed the cached ceiling, and that ceiling may only be
    measured at minimum width.** A fixed 0.25 fraction once asked for 205pt when only 196pt
    was free and macOS hid a neighbouring app's icon (NordVPN's, 2026-08-19).
    **`available` is NOT invariant to our own width — that claim was measured and refuted.**
    Changing only our width moved it from 91pt (at 40pt wide) to 437pt (at 282pt wide),
    because widening evicts leftward neighbours and their vacated space reads back as a
    bigger gap. A measure-then-grow loop therefore ratchets, and re-measuring while
    oversized measures the damage already done. **Only a reading taken at the minimum rung
    is honest** — that is why `remeasureCeiling()` shrinks first, and why ordinary
    track-change relayouts must keep reusing the cache instead of re-reading.
    Other facts that cost time here: free space comes from the occupied block's **left
    edge**, not a sum of widths, because items can overhang the region (one ended 2pt past
    `region.maxX`); **our own item is unfindable in `CGWindowList`**, because macOS hosts
    NSStatusItem windows in the Control Center process, so every entry carries that
    process's pid and window number — take our own rect from `NSWindow.frame`, and note
    only `X` and `width` are comparable (`CGWindowBounds` is top-left origin,
    `NSWindow.frame` bottom-left); `CGWindowList` bounds need no Screen Recording
    permission, only window *titles* do. A **pinned** rung is the deliberate exception and
    stays exempt — the one remaining path that can displace a neighbour.
    **A ceiling measured this way is still not sufficient on its own — see #20.**
20. **`region.minX` is not the leftmost pixel a status item may occupy, so a raw
    gap measurement over-reports free space.** macOS keeps a margin at the left edge of
    `auxiliaryTopRightArea`, and the over-report equals that margin exactly — which is
    wider than an icon, so the item can sit *inside* its own measured ceiling and still
    make macOS hide a neighbour. That is not a hypothetical: it shipped, and hid Scroll
    Reverser's icon on 2026-08-20 with `displayMode=auto`.
    Measured that day on the notched built-in display: with the bar crowded the occupied
    block bottomed out at **x=984..994** against a region starting at **956** — a real
    reserve of ~26pt (max observed block span 746 of 772). The item measured a 202pt window
    ceiling, took 194, and evicted a 30pt neighbour; the true limit was 164, and
    `202 − 164 = 38 = leftEdge − region.minX`. The reserve did **not** move with the
    frontmost app's menus (Finder 992, Terminal 992, Safari 984), so it is not menu overflow.
    `Config.barReserve` (40pt, `defaults` key `barReserve`) is subtracted inside
    `BarLayout.availableWidth`. **Never reintroduce a call that omits it** — the parameter
    is required, not defaulted, for exactly that reason. Setting it to 0 reproduces the bug.
    Verified by counting in-region status windows across a launch: **13 and stable** after
    the fix, where before it dropped to 12 within 200ms. That count is the eviction signal
    decision #16 lacked (see *Things NOT yet done*).

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

## Verifying the no-eviction guarantee (`verify-no-eviction.sh`)

`./verify-no-eviction.sh` is the acceptance test for decision #20, and the only check that
exercises the guarantee this app exists to keep. It compares the count of status windows in
the region with and without our item running.

Two modes, because the two jobs have different costs:

- **no flags — measure only.** Runs against the installed `/Applications` bundle, touches no
  files. Use this on any display you have not tested. It still quits and relaunches the app,
  which is unavoidable: the baseline is the bar *without* our item.
- **`--install`** — also runs `swift build`, the unit checks, and `build-app.sh`, then
  **deletes and replaces `/Applications/SpotifyMenuBar.app`**. This is the pre-PR gate.

**Why a script and not a unit check:** `Config.barReserve` is an empirical constant measured
on one display. No unit test can validate it, because it is a claim about how macOS packs the
bar rather than about our arithmetic. This is the only thing that tests the constant against
reality.

**The invariant: with the app running the count must be exactly one MORE than without it.**
Our item is one window; if the total does not rise, we gained one and somebody else lost one.
Self-calibrating, so there are no hardcoded counts and it holds on any bar or display.

It aborts if `displayMode` is pinned, because a pin bypasses the ceiling by design and would
invalidate the test rather than fail it honestly.

Confirmed bidirectional 2026-08-20 — a test that cannot fail proves nothing:

| `barReserve` | count | our window | verdict |
|---|---|---|---|
| 40 (default) | 12 -> 13 | 156 | PASS |
| 0 | 12 -> 12 | 195 | FAIL, icon evicted |

Run `--install` before opening a PR that touches layout, and the default mode on any display
you have not tested. The invariant is self-calibrating, so the counts move with the bar: the
same script read 12 -> 13 on a crowded bar and 8 -> 9 an hour later, both PASS.

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
- Clip-detection / auto-demotion feedback loop — **abandoned as designed** (decision #16:
  watching our *own* window can never work, because we are the cause and not the clipped
  party). But the signal it needed does exist and was found on 2026-08-20: **the count of
  status windows inside the region drops when macOS hides a neighbour** (measured 13 → 12 on
  eviction, and back to 13 when we shrank). A closed loop on that count is genuine future
  work — it would self-calibrate `Config.barReserve` away, at the cost of one visible blink
  on the eviction path and of disambiguating innocent count changes. Decision #20 took the
  simpler constant instead.
- A status item added or removed by an **already-running** process (Control Center
  toggles, a VPN client's "hide icon" setting) fires none of the notifications that
  re-establish the ceiling, so it can sit stale-high until the next launch/quit/screen/Space
  event. See decision #19 — and note the obvious fix is a trap: clamping on a live reading
  inside `relayout` ratchets *downward* to a permanent play button.

If you add any of these, update `README.md` and this file.
