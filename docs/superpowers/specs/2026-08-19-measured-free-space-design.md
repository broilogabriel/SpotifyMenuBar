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

- **Our own item cannot be identified in the list at all — do not try.** macOS hosts
  `NSStatusItem` windows inside the **Control Center** process: every entry reports Control
  Center's pid (measured: our app pid 24578, the layer-25 window at our exact coordinates
  pid 1126) and therefore Control Center's `kCGWindowNumber`. Matching
  `NSWindow.windowNumber` **never succeeds** and produced a permanently-nil measurement
  when first implemented. `NSWindow.windowNumber` does correspond to `kCGWindowNumber` for
  an ordinary window you create yourself — that correspondence does not extend to a
  status-item window, and assuming it did was the original error here.
- **Take our own rect from `NSWindow.frame` instead**, and use `CGWindowList` purely for the
  collection of other items' `minX`. `X` and `width` are directly comparable between the two
  coordinate systems, which is all `availableWidth` needs. Our own window still appears in
  the list as a Control-Center-owned entry at the same `x`/`width` — numerically close but
  not identical (observed 1pt apart) — which is harmless because `availableWidth` only reads
  `own.width` and the minimum `minX`, both re-queried fresh each call.
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
func statusItemFrames() -> (own: CGRect, all: [CGRect], region: CGRect)?
    region  = currentRegion()
    ownFrame = statusItem.button?.window?.frame
    nil unless ownFrame horizontally intersects region      // not yet placed
    layer   = CGWindowLevelForKey(.statusWindow)            // == 25 here, never hardcode
    windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    all     = windows where layer matches AND bounds intersect region
    nil if all is empty                                     // query gave nothing usable
    own     = CGRect(x: ownFrame.minX, width: ownFrame.width)
```

The "not yet placed" test is a region intersection, not a window lookup: an uncommitted
status window sits outside the bar entirely (observed `{{0, -33}, {84, 33}}`).

### 2. Arithmetic — pure, Core side, unit-tested

```
BarLayout.availableWidth(own: CGRect, all: [CGRect], region: CGRect) -> CGFloat
    let leftEdge = all.map(\.minX).min() ?? own.minX
    return max(own.width + (leftEdge - region.minX), 0)
```

`own` is included in `all`; that is intentional and required for the stability property
below.

### 3. The invariance claim was FALSE — measured 2026-08-19

This section previously argued that `available = own.width + gap` is invariant to our own
width, because growing by *X* raises `own.width` by *X* while lowering `gap` by *X*. **That
is wrong, and it was refuted empirically before any feedback loop was built.**

Changing only our own width, via the Display pin, four consecutive times:

| pinned rung | our width | leftmost neighbour `minX` | `available` |
|---|---|---|---|
| `playPause` | 40 | 1007 | **91** |
| `full` | 282 | 1111 | **437** |

`available` more than quadruples. The arithmetic is correct (`40+51`, `282+155`); the
premise is not. `gap` is measured to the leftmost **visible** item, and as we widen, macOS
*hides* leftward neighbours — so their vacated width reappears as a larger gap. At `full`
the leftmost neighbour sits further **right** (1111) than when we are narrow (1007),
because the items that occupied 1007–1111 are gone.

**Consequence: a measure-then-grow feedback loop is a runaway, not a convergence.** Measure
91 → grow → evict → measure 437 → grow again, ratcheting until it hits the fraction or the
region. Any design that re-measures while oversized is measuring the damage it just did.

### 3a. What is actually trustworthy: measure at minimum

A measurement is only valid **while nothing has been evicted**, which is only reliably true
while our item is at its smallest. On the bar above that yields **91pt** — the genuine
answer to "how much may I take without displacing anyone", and it corresponds to the
`icons` rung (68pt), not `compact`.

So the measurement is a **cached ceiling**, established at minimum width, not a per-layout
reading:

```
barCeiling: CGFloat?        // nil = unknown; forces the minimum rung

budget = min(maxWidthFraction × region.width, barCeiling ?? chrome(.playPause))
```

- Ordinary relayouts (track changes) **never re-measure**. They reuse `barCeiling`, so
  there is no per-track flicker and no opportunity to ratchet.
- `barCeiling` is re-established only by an explicit `remeasureCeiling()` cycle: drop to
  the minimum rung, let the window server settle, measure, cache, then grow once into it.
- That cycle costs one brief shrink-and-regrow. It runs at launch and when the bar's
  contents plausibly changed (app launch/quit, screen change, Space change) — **not** on
  every track change, so the blink is rare rather than constant.

### 4. Budget

```
budget = min(maxWidthFraction × region.width, barCeiling ?? chrome(.playPause))
```

`maxWidthFraction` is retained as the user's "don't hog" preference. `barCeiling` — the
ceiling measured at minimum width, per 3a — is the harder one. A nil ceiling means
"unknown", and the `chrome(.playPause)` fallback makes the item render minimally until the
cycle in section 5 establishes it.

Floored at `chrome(.playPause)` so the item always renders something even when there is
genuinely no room.

### 5. Startup — the ceiling cycle

The first layout cannot measure at all: `statusItem.button?.window?.frame` is
`{{0,-33},…}` before placement (observed), so `statusItemFrames()` returns nil. Combined
with 3a, startup is one instance of the general cycle:

1. `barCeiling` is nil, so the first layout renders `playPause` — the smallest thing, which
   can never be too big and cannot evict anyone.
2. After a short delay (the window server needs a turn to place and size the item),
   measure. If the measurement is still nil, retry — bounded, because a permanently
   unplaced window would otherwise reschedule forever.
3. Cache the result as `barCeiling` and relayout once, growing into it.

The alternative — start at the fraction and correct downward — puts the eviction on the
launch path, which is precisely the reported symptom.

### 6. When the ceiling is re-established

`remeasureCeiling()` runs when the bar's contents plausibly changed:

- at launch (section 5)
- `NSWorkspace.didLaunchApplicationNotification`
- `NSWorkspace.didTerminateApplicationNotification`
- `NSApplication.didChangeScreenParametersNotification`
- `NSWorkspace.activeSpaceDidChangeNotification`

The two `NSWorkspace` ones must be registered on `NSWorkspace.shared.notificationCenter`,
not the default centre, or they never fire.

**Track changes deliberately do NOT re-measure.** They reuse the cached ceiling. This is
what keeps the shrink-and-regrow blink rare and removes any per-track ratchet.

All of these need coalescing — login-item startup delivers app-launch notifications in
bursts, and a burst of `remeasureCeiling()` calls would blink repeatedly. Coalesce on a
work item **separate** from the existing `pendingRefresh`, which covers only
`PlaybackStateChanged`; sharing it would let a track change cancel a pending measurement.

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
| ~~The stability property~~ | **Removed — the property is false (section 3).** The Task 1 sweep that asserts a constant 196 checks the *arithmetic* under a synthetic packed-block model, which is fine as an arithmetic check, but it must not be read as evidence about real bar behavior. |
| Budget composition — measurement as the harder ceiling; pin exempt | Core checks over `plan` |
| Compiles / nothing regressed | `swift build`, existing 93 checks unmodified (one check's message was deliberately reworded when the invariance property it asserted was refuted; the assertion and swept values did not change) |
| Bundle still assembles | `./build-app.sh` |
| The reported bug is fixed | manual: crowd the bar, launch the app, confirm **no** neighbour icon disappears — the check that matters. `debugLayout` shows `available=` next to `requested=`; on a crowded bar expect the item to settle at `icons` or `playPause`, which is the honest cost of never evicting |
| The ceiling does not ratchet | manual: with `debugLayout` on, watch across several track changes that `available=` stays constant (it is cached, not re-read) and the rung does not creep upward |
| Grow-in is not objectionable | manual: watch the item at launch |

## Documentation to update

- **AGENTS.md** — a new "do not regress" entry: the automatic path must never exceed
  measured `available`, and why (it displaced NordVPN's icon); that the pin is the
  deliberate exception. Also that `CGWindowList` bounds need no permission but titles do.
- **README.md** — the space behavior is now measured rather than a fixed share; the
  known-limitation wording about a crowded bar should narrow to the pinned case only.
- The superseded spec's section 5 already points forward; add a pointer to this file.
