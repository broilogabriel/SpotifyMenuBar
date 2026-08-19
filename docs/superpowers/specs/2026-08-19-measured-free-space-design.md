# Measured menu-bar free space — design

**Date:** 2026-08-19
**Status:** approved design, pending implementation plan
**Scope:** `Sources/SpotifyMenuBarCore/BarLayout.swift`, `Sources/SpotifyMenuBar/main.swift`,
`Sources/SpotifyMenuBarCoreTests/main.swift`, `AGENTS.md`, `README.md`
**Supersedes:** the clip-feedback mechanism in
`docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md` section 5, which was
probed and abandoned.

## Problem

The shipped app caps its status item at a fixed fraction of the status-item region
(`maxWidthFraction`, default 0.25). That stops it being *unboundedly* greedy, but the
fraction is a guess with no relationship to how much room is actually free — so it can
still displace another app's icon.

Observed on the built-in notched display, 2026-08-19. Launching the app onto a crowded bar
hid NordVPN's icon (its process stayed alive). Measurements at that moment:

| Quantity | Value |
|---|---|
| Status-item region (`auxiliaryTopRightArea`) | x 956 → 1728, **772pt** |
| Occupied block (all layer-25 windows) | x 1068 → 1730, contiguous, right-aligned |
| Free space | x 956 → 1068, **112pt**, one block on the left |
| Our item | x 1068, **84pt** wide (leftmost) |
| Space actually available to us | 84 + 112 = **196pt** |
| What the `compact` rung requested | **205pt** |

205 > 196 by 9pt. The item took the space and macOS dropped the leftmost neighbour. The
fixed fraction (0.25 × 772 = 193pt) sat just over a line it had no way to see.

## Why the previous mechanism could not fix this

The abandoned design watched our *own* window for evidence that *we* had been clipped. In
the observed failure we were never clipped — we were granted our request and stayed
`visible=Y`; somebody else was evicted. Full reasoning and data in the superseded spec's
section 5. The lesson carried forward: **the quantity that matters is other apps' geometry,
not our own state.**

## Key finding this design rests on

`CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)` returns bounds, owner
PID and window layer for every on-screen window, **with no Screen Recording permission**.
Only window *titles* (`kCGWindowName`) are gated. Verified 2026-08-19: the call succeeded
unprompted and returned all 13 status-item windows with exact geometry.

Two properties of the result that shape the design:

- **All status items report owner "Control Centre"** (macOS hosts them in that process), so
  identification by owner name is impossible. Identify our own item by
  **`statusItem.button?.window?.windowNumber` matched against `kCGWindowNumber`** —
  verified 2026-08-19 to correspond exactly.
- **Do NOT match on frames.** `CGWindowBounds` uses a **top-left** origin while
  `NSWindow.frame` uses **bottom-left**; a test window at `NSWindow` y=300 reported
  `CGWindow` Y=793. `X` and `Width` agree, `Y` does not, so frame equality silently never
  matches.
- **The window must be committed to the window server before it appears in the list.** The
  same probe found no match until a runloop turn had passed. This is independent
  confirmation of the start-minimal-then-grow ordering in section 5 — the first layout
  genuinely cannot measure.
- **The rightmost item overhung the region by 2pt** (ended at 1730 vs `region.maxX` 1728).
  So free space must be derived from the occupied block's **left edge**, not by summing
  widths, which would be off by the overhang and by any inter-item gaps.

## Non-goals

- Detecting that *we* were clipped. Probed, abandoned, see the superseded spec.
- Preventing eviction caused by a *pinned* rung — that is a deliberate user override.
- Reacting to status items added or removed via System Settings (no app launch, so no
  notification). Picked up at the next ordinary re-layout.
- Any polling or timer. This app has none and gains none.

## Design

### 1. Measurement — environment access, AppKit side

Lives beside the existing `currentRegion()` in `main.swift`, because it queries the window
server. Returns nil when our own window is not yet placed.

```
func statusItemFrames() -> (own: CGRect, all: [CGRect])?
    layer  = CGWindowLevelForKey(.statusWindow)      // == 25 here, but never hardcode it
    windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    keep    = windows where layer matches AND bounds intersect this screen's region
    own     = the entry matching statusItem.button?.window?.frame
    nil unless own is found
```

### 2. Arithmetic — pure, Core side, unit-tested

```
BarLayout.availableWidth(own: CGRect, all: [CGRect], region: CGRect) -> CGFloat
    let leftEdge = all.map(\.minX).min() ?? region.maxX
    return max(own.width + (leftEdge - region.minX), 0)
```

`own` is included in `all`; that is intentional and required for the stability property
below.

### 3. Why this cannot oscillate

`available = own.width + gap`. Growing by *X* increases `own.width` by *X* and decreases
`gap` by *X*, so **`available` is invariant to our own width**. Re-measuring after a resize
yields the same number, so the grow-in converges in one step and needs no hysteresis, no
damping and no timer.

This holds only while we stay within `available`. Exceeding it evicts a neighbour, whose
vacated width then *increases* the measured gap — a runaway. The never-evict rule below is
what keeps the invariant true.

### 4. Budget

```
budget = min(maxWidthFraction × region.width, available)   // measurable
       = chrome(.playPause)                                // not yet placed
```

`maxWidthFraction` is retained as the user's "don't hog" preference. The measurement is a
second, harder ceiling. **The automatic path never exceeds `available`, so it can never
displace another app's icon.**

### 5. Startup — start minimal, then grow

The first layout cannot measure: `statusItem.button?.window?.frame` is `{{0,-33},…}` before
placement (observed). So:

1. First layout renders `playPause` (24pt) — the smallest thing that is never too big.
2. On the next runloop turn, measure and re-layout into the real budget.

One bounded re-layout, not a loop. The cost is a brief visible expand at launch. This
ordering is deliberate: the alternative — start at the fraction and correct downward — puts
the eviction bug on the launch path, which is exactly the reported symptom.

### 6. Re-measure triggers

The three already wired (`refresh`/track change, `didChangeScreenParametersNotification`,
`activeSpaceDidChangeNotification`) plus two new ones, because app launch and quit is when
the bar's contents actually change:

- `NSWorkspace.didLaunchApplicationNotification`
- `NSWorkspace.didTerminateApplicationNotification`

Both on `NSWorkspace.shared.notificationCenter` — not the default center, or they never
fire.

**These need their own coalescing.** The existing `pendingRefresh` debounce covers only
`PlaybackStateChanged`; `screenChanged()` relayouts immediately. Login-item startup or a
Space full of app launches can deliver these in bursts, so route them through the same
~100ms coalescing pattern rather than calling `relayout` per notification. Reuse the
mechanism, not the variable — a shared `pendingRefresh` would let a track change cancel a
pending measurement or vice versa.

### 7. A pinned rung is exempt

Settled explicitly: **the pin wins.** A pin is the user overruling the safety margin, which
is the entire point of the Display submenu, and capping it to free space would make the
menu a hint rather than a setting. `BarLayout.pin` keeps its current `regionWidth` ceiling
and does **not** take `available`.

Consequence, to be documented rather than hidden: a pinned larger rung remains the one route
by which this app can still displace a neighbour. The automatic path cannot.

## Structure

| Unit | Purpose | Depends on |
|---|---|---|
| `statusItemFrames()` (`main.swift`) | Ask the window server which status items exist and which is ours. | AppKit, CoreGraphics |
| `BarLayout.availableWidth(own:all:region:)` | Turn those rects into a width. Pure. | CoreGraphics |
| `BarLayout.plan(...)` | Unchanged entry point; gains an `available` parameter. | Core |
| `AppDelegate.relayout` | Unchanged shape; passes the measurement through. | AppKit |

The split matches the existing discipline: the window-server query is untested environment
access like `currentRegion()`; every decision derived from it is pure and checked.

## Failure modes

Each degrades to **today's** behavior — fraction-only sizing — never to something worse.

| Condition | Behavior |
|---|---|
| `CGWindowListCopyWindowInfo` returns nil or empty | `available` unknown → fraction-only budget |
| Our own frame not found (unplaced, or geometry match fails) | Treated as first layout → `playPause`, then retry next turn |
| A future OS gates window bounds behind a permission | Fewer/no windows returned → fraction-only budget |
| Region width zero or absurd | Existing `budget` clamps still apply (floored at `playPause` chrome) |
| Items overhang the region (observed: 2pt) | Left-edge derivation is unaffected; result clamped at ≥ 0 |
| Multiple displays | Items filtered to those intersecting our own screen's region |
| `available` smaller than `playPause` chrome | `budget` floor wins; the item still renders something |

## Settings

No new keys. `debugLayout` gains `available=` in its log line, which is how this design
would have been diagnosed in the first place.

## Verification

| What | How |
|---|---|
| `availableWidth` arithmetic — leftmost derivation, own-inclusion, overhang, empty `all`, clamping at 0 | `swift run SpotifyMenuBarCoreTests`, synthetic `CGRect`s |
| The stability property — `available` invariant as `own.width` varies | a swept check over widths, asserting a constant result |
| Budget composition — measurement as the harder ceiling; pin exempt | Core checks over `plan` |
| Compiles / nothing regressed | `swift build`, existing 83 checks unmodified |
| Bundle still assembles | `./build-app.sh` |
| The reported bug is fixed | manual: crowd the bar, launch the app, confirm **no** neighbour icon disappears — this is the check that matters, and `debugLayout` will show `available=` next to `requested=` |
| Grow-in is not objectionable | manual: watch the item at launch |

## Documentation to update

- **AGENTS.md** — a new "do not regress" entry: the automatic path must never exceed
  measured `available`, and why (it displaced NordVPN's icon); that `available` is invariant
  to our own width and that is what makes the grow-in terminate; that the pin is the
  deliberate exception. Also that `CGWindowList` bounds need no permission but titles do.
- **README.md** — the space behavior is now measured rather than a fixed share; the
  known-limitation wording about a crowded bar should narrow to the pinned case only.
- The superseded spec's section 5 already points forward; add a pointer to this file.
