# Menu-bar space adaptation — design

**Date:** 2026-08-18
**Status:** approved design, pending implementation plan
**Scope:** `Sources/SpotifyMenuBar/main.swift`, `Package.swift`, `AGENTS.md`, `README.md`

## Problem

`resize()` sets `statusItem.length = stack.fittingSize.width + 8` with no ceiling. The
item asks for whatever its content wants. When the sum of all status items exceeds the
bar, macOS does not shrink items — it hides them, right to left. A greedy item therefore
evicts its neighbours and eventually itself.

Measured on the built-in Retina display of this machine, 2026-08-18:

| Quantity | Value |
|---|---|
| `screen.frame.width` | 1728pt |
| Notch region | x 771 → 956 (185pt) |
| `auxiliaryTopRightArea` — the entire status-item region | x 956 → 1728 (**772pt**) |
| `NSFont.menuBarFont(ofSize: 0)` | 13pt |
| Item width at `"Bohemian Rhapsody – Queen"` | ~256pt = **33%** of the region |
| Item width at `maxTrack` + `maxArtist` = 18 + 18 | ~350pt = **45%** of the region |

One Spotify item can claim nearly half the region that Control Center, the clock,
battery, Wi-Fi and every other third-party item share. That is the mechanism.

macOS exposes no API for remaining menu-bar space; other apps' items are invisible to us.
So the fix cannot be "measure what's left" — it is "never be greedy", with a corrective
feedback loop layered on top.

## Non-goals

- Scrolling/marquee track text.
- Rendering to the left of the notch (that region belongs to app menus; status items
  never wrap into it).
- Multiple status items (regresses AGENTS.md decision #1, which this bug already proves).
- Any Spotify Web API, network, or OAuth use.

## Design

Two independent mechanisms, because shrinking text and dropping controls are different
problems.

### 1. Budget — pure function of screen geometry

```
region = screen.auxiliaryTopRightArea, if non-nil AND width > 0   // notched: 772pt here
       | right half of screen.frame, otherwise                    // non-notched display
budget = clamp(region.width × maxWidthFraction, low: chrome(.playPause), high: region.width)
```

**Verified 2026-08-18:** Swift imports `auxiliaryTopRightArea` as **`NSRect?`**, even though
the ObjC header declares it non-optional `NSRect`. "No notch" is therefore signalled by
*either* nil *or* an empty rect, and both must be handled — checking only `.isEmpty` will
not compile.

`screen` is the display owning the status button's window, not `NSScreen.main`, so docking
to an external monitor recomputes the budget.

`maxWidthFraction` defaults to **0.25** → 193pt here. After chrome that leaves ~119pt of
text ≈ 17 characters at 13pt, close to today's `maxTrack` of 18, so the common case looks
unchanged.

### 2. Rungs — the discrete content shapes

`enum Rung: full, compact, icons, playPause`, in degradation order. Chrome width is
`buttons + inter-view spacing + 8pt padding`, from the existing `Config` values
(`buttonWidth: 16`, `stackSpacing: 6`):

| Rung | Content | Chrome | Total |
|---|---|---|---|
| `full` | `Track – Artist` + ⏮ ⏯ ⏭ | 74pt | 74 + label |
| `compact` | `Track` + ⏮ ⏯ ⏭ | 74pt | 74 + label |
| `icons` | ⏮ ⏯ ⏭ | 68pt | 68pt |
| `playPause` | ⏯ only; prev/next move into the right-click menu | 24pt | 24pt |

`playPause` is the floor: the item always renders something, never nothing.

### 3. Text fitting — pixels, not characters

Labels are measured with `(text as NSString).size(withAttributes: [.font: menuBarFont])`.
`maxTrack` / `maxArtist` remain the user's *preferred* upper bound; pixels are the hard
constraint. `Config.minLabelWidth = 40pt` (compile-time, not exposed as a setting) — below
that a label is not legible and the resolver drops to `icons` rather than showing a lone
ellipsis.

Text measurement is AppKit-only (`NSAttributedString`/`NSString.size(withAttributes:)` are
not in Foundation on macOS), so **`AppDelegate` supplies the measuring closure and
`BarLayout` receives it**. That keeps the core AppKit-free and lets tests inject a stub
whose widths are font-independent.

### 4. Resolution algorithm

`BarLayout.resolve` is pure and deterministic:

```
budget = clamp(regionWidth × fraction, low: chrome(.playPause), high: regionWidth)

full:       labelBudget = budget − chrome(.full)
            if labelBudget ≥ minLabelWidth
               and measure("trunc(track,maxTrack) – trunc(artist,maxArtist)") ≤ labelBudget
            → (.full, that text)

compact:    labelBudget = budget − chrome(.compact)
            if labelBudget ≥ minLabelWidth:
               if measure("trunc(track,maxTrack)") ≤ labelBudget → (.compact, that text)
               else if ellipsisFit(track, labelBudget) is non-nil → (.compact, fitted text)

icons:      if chrome(.icons) ≤ budget → (.icons, nil)

playPause:  → (.playPause, nil)      // unconditional floor
```

`ellipsisFit` shrinks the string and appends `…` until the measured width fits, returning
nil if even one character plus the ellipsis overflows. `full` is chosen only when the
preferred string fits *without* pixel truncation; anything tighter drops the artist first,
which matches the stated priority (controls survive, text degrades).

### 5. Clip feedback

After applying a resolution and setting `statusItem.length`, on the next runloop turn:

```
verdict = clipVerdict()
if verdict == .clipped and rung is not .playPause:
    rung = next(rung); apply; repeat        // bounded at 3 iterations
```

`clipVerdict() -> Clip` is three-state — `.clipped`, `.notClipped`, `.unknown`:

```
guard let button = statusItem.button,
      let window = button.window,
      let screen = window.screen           else { return .unknown }
if !statusItem.isVisible                    { return .clipped }
if window.frame.width + 0.5 < requestedLength { return .clipped }
if window.frame.minX < barRegion(screen).minX − 0.5 { return .clipped }
return .notClipped
```

**`.unknown` falls back to the computed ceiling alone.** This is deliberate: the design
must still work if macOS gives us no usable clipping signal.

No timer and no hysteresis machinery. The loop is bounded and deterministic per
evaluation, so it cannot flap; and because every evaluation restarts from the
budget-derived rung, the item recovers upward on its own once the bar empties.

**Unverified assumption — first task in the plan.** Which of those three predicates
actually fires when macOS clips a status item has not been confirmed; it cannot be, from a
non-interactive session, because `swift run` launches a blocking GUI app. The probe is to
log `statusItem.isVisible`, `window.frame` and the region at each rung while crowding the
bar, and identify the field that moves. If none do, `clipVerdict` is hardcoded to
`.unknown` and the feature ships ceiling-only. Everything else in this design is unaffected.

### 6. Re-evaluation triggers

- The existing `refresh()` — already runs on every track change and every debounced
  `PlaybackStateChanged`.
- `NSApplication.didChangeScreenParametersNotification` — dock/undock, resolution change.
- `NSWorkspace.shared.notificationCenter` / `activeSpaceDidChangeNotification`.

No polling.

### 7. Manual override

A `Display` submenu on the existing right-click menu: **Auto** (default) / Full / Compact /
Icons / Play-pause only. A fixed pick pins the rung and skips both budget and feedback.
The checkmark is set in the existing `menuNeedsUpdate(_:)`, matching how the login item
already works (AGENTS.md decision #8 — the menu is built once).

Persisted as `displayMode` in `UserDefaults`.

## Structure

Three units, one purpose each:

| Unit | Purpose | Depends on |
|---|---|---|
| `Rung` | The four content shapes and their order. Knows what a rung *contains*, nothing about views. | — |
| `BarLayout` | Pure resolver: region width, fraction, chrome metrics, track/artist, a measuring closure → `(rung, labelText, totalWidth)`. No views, no `NSStatusItem`, no clock. | Foundation |
| `AppDelegate` | Applies a resolution to the views; owns clip detection and the `Display` menu. | AppKit |

All the arithmetic that can be wrong lives in `BarLayout` and is deterministic.

### Package layout

SwiftPM cannot test an executable target, so the pure core moves to a library:

```
Package.swift
├── Sources/SpotifyMenuBarCore       (library)     Config, Settings, trunc, Rung,
│                                                  DisplayMode, BarLayout
├── Sources/SpotifyMenuBar           (executable)  main.swift — AppKit only, → Core
└── Sources/SpotifyMenuBarCoreTests  (executable)  Harness.swift + main.swift, → Core
```

- **`swift-tools-version` stays at 5.9.** Bumping to 6.0 would also switch the package to
  Swift 6 language mode, whose strict concurrency checking would ripple into the AppKit
  code (`@MainActor`, `Sendable` on `SpotifyClient`). Out of scope.
- **Tests are a plain executable, not a `.testTarget`.** Verified 2026-08-18: this machine
  has no Xcode (`xcode-select -p` → `/Library/Developer/CommandLineTools`), and the Command
  Line Tools toolchain ships **neither `XCTest` nor swift-testing's `Testing` module** —
  both fail with `no such module`, so a `.testTarget` cannot compile here at all and
  `swift test` is unavailable. Instead `SpotifyMenuBarCoreTests` is an
  `.executableTarget` under `Sources/` with a ~30-line `expect`/`summarize` harness that
  exits non-zero on failure. Run with `swift run SpotifyMenuBarCoreTests`. This keeps the
  "no third-party dependencies" rule intact and needs no Xcode install.
- `Settings.current(_ defaults: UserDefaults = .standard)` gains the parameter so tests
  can inject a suite.
- `build-app.sh` copies `.build/release/SpotifyMenuBar`; the executable name does not
  change and the library links statically, so the bundle stays self-contained. Verify by
  running it.
- This splits the previously single-file app. AGENTS.md says "keep it a single file unless
  it grows substantially" — the split is accepted here specifically to make the sizing
  arithmetic testable, and AGENTS.md is updated to say so.

### View mutation

Rungs are applied with `isHidden` on `label`, `prev` and `next`. `NSStackView` drops
hidden views from layout, so there is no add/remove churn and the `.menu` assignments from
decision #5 stay intact. One status item (#1), trailing anchor (#2) and length-from-
`fittingSize` (#6) are all preserved — the length is simply clamped to the budget now.

### Things that must not silently regress at reduced rungs

The label currently carries both of these, so hiding it breaks them:

- **Tooltip** — the full `"Track – Artist"` string moves onto the status button and each
  icon button, so hovering still reveals the track when the text is gone.
- **VoiceOver** — the host button gets an `accessibilityLabel` carrying the full title, so
  the track is still announced at `icons` and `playPause`. Otherwise decision #12 quietly
  breaks.

## Failure modes

Every condition resolves to a rung, never to an exception.

| Condition | Behavior |
|---|---|
| `auxiliaryTopRightArea` empty (non-notched external display) | right half of `screen.frame` |
| `button.window` or its `screen` nil (early launch) | `clipVerdict` → `.unknown`; ceiling only |
| No screen at all | last known budget, else a 200pt constant |
| `maxWidthFraction` garbage from `defaults write` | clamped to [0.10, 1.0], per the existing #13 pattern |
| `displayMode` unrecognised string | treated as `auto` |
| Region width zero or absurd (virtual displays) | budget floored at `chrome(.playPause)`, so we never request 0 |
| Spotify not running | existing `reset()`, then the resolved rung; the `♪` placeholder drops at `icons` and below |
| Clip loop would exceed 3 steps | stops at `playPause` |

## Settings keys

| Key | Type | Default | Clamp |
|---|---|---|---|
| `maxTrack` | Int | 18 | ≥ 1 (existing) |
| `maxArtist` | Int | 18 | ≥ 1 (existing) |
| `prevRestartSecs` | Double | 3.0 | ≥ 0 (existing) |
| `maxWidthFraction` | Double | 0.25 | [0.10, 1.0] |
| `displayMode` | String | `auto` | one of auto/full/compact/icons/playPause |

## Verification

| What | How |
|---|---|
| `BarLayout` arithmetic — fraction math, notch fallback, rung selection, `ellipsisFit`, clamps | `swift run SpotifyMenuBarCoreTests` (exit 0 = pass), with a stub measuring closure so checks are font-independent |
| Compiles | `swift build` |
| Bundle still assembles and runs | `./build-app.sh`, then launch the `.app` |
| Clip detection signal | manual probe on a crowded bar (task 1 of the plan) — needs the human |
| Rung transitions look right | manual: crowd the bar, dock/undock an external display |

## Documentation to update

- **AGENTS.md** — new "do not regress" entries: never request more than the budget; the
  rung ladder and its floor; `clipVerdict` is deliberately three-state; tooltip and
  `accessibilityLabel` carry the title at reduced rungs. Also the new `Settings` keys, the
  `Display` submenu, and the reason the single-file rule was relaxed.
- **README.md** — the `Display` submenu and the `maxWidthFraction` / `displayMode` keys.
