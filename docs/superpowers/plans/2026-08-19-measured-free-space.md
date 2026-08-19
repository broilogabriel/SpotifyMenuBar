# Measured Menu-Bar Free Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the status item displacing other apps' menu-bar icons, by capping its width at the free space it can actually measure instead of a fixed guess.

**Architecture:** `CGWindowListCopyWindowInfo` yields every status item's geometry (no permission needed). A thin AppKit query returns our own rect plus all of them; a pure Core function turns those into an available width; the existing `BarLayout.plan` takes that as a second, harder ceiling alongside `maxWidthFraction`.

**Tech Stack:** Swift 5.9 (tools-version), AppKit, CoreGraphics, SwiftPM, macOS 13+. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-19-measured-free-space-design.md`

## Global Constraints

- No third-party dependencies. No SwiftUI. Plain Swift + AppKit only.
- `swift-tools-version` stays at `5.9`. Do not bump it.
- **`SpotifyMenuBarCore` must never `import AppKit`.** Foundation + CoreGraphics only. The window-server query belongs in `Sources/SpotifyMenuBar/main.swift`; only pure arithmetic goes in Core.
- **No `XCTest`, no swift-testing, no `.testTarget`, no `swift test`** — this machine has no Xcode and the toolchain ships neither module. Tests are the `SpotifyMenuBarCoreTests` **executable** target, run with `swift run SpotifyMenuBarCoreTests`. `summarize()` must remain the last statement of its `main.swift`; append new checks immediately above it.
- **NEVER run `swift run` bare or `swift run SpotifyMenuBar`** — it launches a blocking GUI app. `swift run SpotifyMenuBarCoreTests` is the only one permitted; it exits on its own.
- **Do not regress `AGENTS.md` decisions 1–18.** Most relevant: one `NSStatusItem`; trailing anchor; `.menu` on every interactive subview; `statusItem.length` from the stack's `fittingSize`; icon buttons keep `accessibilityDescription`; `Settings` clamps `UserDefaults`; **`BarLayout.labelText(for:track:artist:settings:)` is the only place a bar label string is composed**; a pinned rung deliberately overrides the budget.
- No AI attribution anywhere. Conventional Commits, imperative, lower-case, no trailing period. Comment the *why*, not the *what*.
- **Baseline: 83 checks pass today.** Every count below is cumulative and was produced by running a prototype, not derived by hand.
- **Never edit an existing expected value to make a check pass.** If a refactor breaks one, the refactor is wrong. Call-site updates (adding a new argument) are not expectation changes and are expected in Task 3.
- Verified environment facts you may rely on: `CGWindowLevelForKey(.statusWindow) == 25`; **our own status item cannot be located in `CGWindowList`** — macOS hosts NSStatusItem windows in the Control Center process, so every entry carries Control Center's pid and window number (`NSWindow.windowNumber` matching never succeeds; it works only for ordinary windows you create yourself); `CGWindowBounds` uses a **top-left** origin while `NSWindow.frame` uses **bottom-left**, so only `X` and `Width` are comparable.

---

### Task 1: `BarLayout.availableWidth` — the pure arithmetic

**Files:**
- Modify: `Sources/SpotifyMenuBarCore/BarLayout.swift` (add one static function)
- Modify: `Sources/SpotifyMenuBarCoreTests/main.swift` (append checks above `summarize()`)

**Interfaces:**
- Consumes: `Rung`, `Rung.Metrics` (existing).
- Produces: `public static func availableWidth(own: CGRect, all: [CGRect], region: CGRect) -> CGFloat`

- [ ] **Step 1: Write the failing checks**

Append to `Sources/SpotifyMenuBarCoreTests/main.swift`, immediately above `summarize()`:

```swift
// MARK: availableWidth

// Real geometry, measured on the notched built-in display 2026-08-19: region 956..1728,
// our item at x=1068 w=84 was the leftmost of 13 status items, leaving one 112pt free
// block on the left. The last neighbour ends at 1730 — 2pt past region.maxX.
let regionR = CGRect(x: 956, y: 1085, width: 772, height: 32)
let us = CGRect(x: 1068, y: 1084, width: 84, height: 33)
let neighbours = [us,
                  CGRect(x: 1152, y: 1084, width: 34, height: 33),
                  CGRect(x: 1586, y: 1084, width: 144, height: 33)]

expectClose(Double(BarLayout.availableWidth(own: us, all: neighbours, region: regionR)),
            196, "leftmost item: our own width plus the free block")

// An item to our left eats the room we could grow into.
let leftOfUs = CGRect(x: 1000, y: 1084, width: 68, height: 33)
expectClose(Double(BarLayout.availableWidth(own: us, all: neighbours + [leftOfUs], region: regionR)),
            128, "an item to our left reduces what we can claim")

// The right-hand overhang must not change the answer — that is exactly why the occupied
// block's LEFT edge is used instead of a sum of widths.
let overhanging = Array(neighbours.dropLast()) + [CGRect(x: 1586, y: 1084, width: 999, height: 33)]
expectClose(Double(BarLayout.availableWidth(own: us, all: overhanging, region: regionR)),
            196, "a right-hand overhang does not change the result")

expectClose(Double(BarLayout.availableWidth(own: us, all: [], region: regionR)),
            196, "a degenerate empty list falls back to our own position")

// An item overhanging the region's LEFT edge must not yield a negative width.
expectClose(Double(BarLayout.availableWidth(own: us,
                                            all: [CGRect(x: 100, y: 1084, width: 40, height: 33)],
                                            region: regionR)),
            0, "an item left of the region clamps to zero")

// The property the whole design rests on: `available` must not move as our own width
// changes, or the grow-in in Task 4 would oscillate forever.
var availableStable = true
for w in stride(from: CGFloat(24), through: 400, by: 4) {
    // The item's right edge is fixed; width grows leftward, so minX moves left.
    let grown = CGRect(x: us.maxX - w, y: us.minY, width: w, height: us.height)
    let others = neighbours.filter { $0 != us } + [grown]
    if abs(BarLayout.availableWidth(own: grown, all: others, region: regionR) - 196) > 0.001 {
        availableStable = false
    }
}
expect(availableStable, true, "available is invariant to our own width")
```

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: FAIL to compile — `error: type 'BarLayout' has no member 'availableWidth'`

- [ ] **Step 3: Write the implementation**

Add to `BarLayout` in `Sources/SpotifyMenuBarCore/BarLayout.swift`, after `budget`:

```swift
    /// How much width this item may occupy without displacing a neighbour.
    ///
    /// `own` is expected to be one of `all`, and that inclusion is load-bearing:
    /// `available = own.width + gap`, so growing by X raises `own.width` by X while
    /// lowering `gap` by X and the result does not move. That invariance is why the
    /// grow-in converges in one step and needs no hysteresis, damping or timer.
    ///
    /// Derived from the occupied block's LEFT edge rather than a sum of widths, because
    /// status items can overhang the region (measured: one ended 2pt past `region.maxX`)
    /// and can sit with gaps between them — either makes a sum disagree with reality.
    public static func availableWidth(own: CGRect, all: [CGRect], region: CGRect) -> CGFloat {
        let leftEdge = all.map(\.minX).min() ?? own.minX
        return max(own.width + (leftEdge - region.minX), 0)
    }
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `89/89 checks passed`, exit 0 (83 + 6).

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyMenuBarCore/BarLayout.swift Sources/SpotifyMenuBarCoreTests/main.swift
git commit -m "feat(layout): compute available width from status-item geometry"
```

---

### Task 2: `statusItemFrames()` — ask the window server

Environment access, so it lives in the AppKit file and carries no automated check, exactly like the existing `currentRegion()`. It also extends the `debugLayout` line, which is how this whole design was discovered.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (add `statusItemFrames()`; extend `logLayout`)

**Interfaces:**
- Consumes: `currentRegion()`, `statusItem` (existing); `BarLayout.availableWidth` (Task 1).
- Produces: `func statusItemFrames() -> (own: CGRect, all: [CGRect])?`; `func measuredAvailable() -> CGFloat?`

- [ ] **Step 1: Add the query**

Add to `AppDelegate`, immediately after `currentRegion()`:

```swift
    /// The status-item windows currently on screen, and which one is ours.
    ///
    /// `CGWindowListCopyWindowInfo` needs **no** Screen Recording permission for bounds —
    /// only window titles (`kCGWindowName`) are gated. Every status item reports owner
    /// "Control Centre" because macOS hosts them in that process, so ours is identified by
    /// `windowNumber`, which corresponds exactly to `kCGWindowNumber`.
    ///
    /// Returns nil until our window is committed to the window server; before that it is
    /// simply absent from the list, which is the "cannot measure yet" case Task 4 handles.
    func statusItemFrames() -> (own: CGRect, all: [CGRect])? {
        guard let window = statusItem.button?.window else { return nil }
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ourNumber = window.windowNumber
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let region = currentRegion()
        var own: CGRect?
        var all: [CGRect] = []
        for entry in raw {
            guard (entry[kCGWindowLayer as String] as? Int) == statusLayer,
                  let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let w = b["Width"] else { continue }
            // CGWindowBounds is top-left origin, NSWindow.frame is bottom-left, so only X
            // and Width are comparable. Synthesise y/height from the region rather than
            // trusting a value we cannot compare.
            let rect = CGRect(x: x, y: region.minY, width: w, height: region.height)
            // Keep only items on this screen's status area (multi-display).
            guard rect.maxX > region.minX, rect.minX < region.maxX else { continue }
            all.append(rect)
            if (entry[kCGWindowNumber as String] as? Int) == ourNumber { own = rect }
        }
        guard let own else { return nil }
        return (own, all)
    }

    /// Measured free space, or nil when the item is not yet placed.
    func measuredAvailable() -> CGFloat? {
        guard let frames = statusItemFrames() else { return nil }
        return BarLayout.availableWidth(own: frames.own, all: frames.all, region: currentRegion())
    }
```

- [ ] **Step 2: Surface it in the diagnostic**

In `logLayout`, add `available=` to the message. Replace the `let msg = …` chain's final line so the built string ends with the new field:

```swift
            + " windowFrame=\(w.map { NSStringFromRect($0.frame) } ?? "nil")"
            + " available=\(measuredAvailable().map { String(format: "%.1f", $0) } ?? "nil")"
```

- [ ] **Step 3: Verify build and that nothing regressed**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `89/89 checks passed`, exit 0 (unchanged; this task adds no checks).

- [ ] **Step 4: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat(menubar): read status-item geometry from the window server"
```

---

### Task 3: Make the measurement a second ceiling in `plan`

**Files:**
- Modify: `Sources/SpotifyMenuBarCore/BarLayout.swift` (`plan` gains `available:`)
- Modify: `Sources/SpotifyMenuBar/main.swift` (both `BarLayout.plan` call sites in `relayout`)
- Modify: `Sources/SpotifyMenuBarCoreTests/main.swift` (update 3 existing `plan` call sites; append 4 checks)

**Interfaces:**
- Consumes: `BarLayout.budget`, `BarLayout.resolve`, `BarLayout.pin`, `Rung.playPause.chromeWidth` (existing).
- Produces: `public static func plan(track:artist:regionWidth:fraction:available:pin:settings:metrics:measure:) -> Resolution` — note the **new `available: CGFloat?`** parameter, placed after `fraction:`.

- [ ] **Step 1: Write the failing checks**

First, **update the 3 existing `plan` call sites** in `Sources/SpotifyMenuBarCoreTests/main.swift` by inserting `available: nil,` after their `fraction: 0.25,` argument. Their expected values do **not** change — this is a signature update, not an expectation change.

Then append above `summarize()`:

```swift
// MARK: plan — measured free space as a second ceiling

// available (100) is tighter than the fraction (0.25 x 772 = 193), so it wins: a 100pt
// budget leaves 26pt of label room, below minLabelWidth, so the ladder drops to icons.
expect(BarLayout.plan(track: "Bohemian Rhapsody", artist: "Queen", regionWidth: 772,
                      fraction: 0.25, available: 100, pin: nil, settings: st, metrics: m,
                      measure: measure).rung, .icons,
       "measured free space caps the fraction")

// An unmeasurable bar must behave exactly as before this change.
expect(BarLayout.plan(track: "Bohemian Rhapsody", artist: "Queen", regionWidth: 772,
                      fraction: 0.25, available: nil, pin: nil, settings: st, metrics: m,
                      measure: measure).rung, .compact,
       "an unmeasurable bar falls back to the fraction alone")

// A pin is the user overruling the safety margin — the whole point of the Display
// submenu — so it ignores the measurement entirely.
expect(BarLayout.plan(track: "Bohemian Rhapsody", artist: "Queen", regionWidth: 772,
                      fraction: 0.25, available: 30, pin: .full, settings: st, metrics: m,
                      measure: measure).rung, .full,
       "a pinned rung ignores measured free space")

// The floor still wins: the item always renders something.
expect(BarLayout.plan(track: "Bohemian Rhapsody", artist: "Queen", regionWidth: 772,
                      fraction: 0.25, available: 5, pin: nil, settings: st, metrics: m,
                      measure: measure).rung, .playPause,
       "an absurdly small measurement still renders the floor")
```

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: FAIL to compile — `error: extraneous argument label 'available:'`

- [ ] **Step 3: Write the implementation**

Replace `BarLayout.plan` in `Sources/SpotifyMenuBarCore/BarLayout.swift` with:

```swift
    /// The whole layout decision: resolve against the budget, then let a user pin
    /// override the rung. One place, so the two callers cannot drift.
    ///
    /// `available` is measured free space (nil when unmeasurable). It is a *harder*
    /// ceiling than `fraction`: exceeding it makes macOS hide a neighbouring app's icon,
    /// which is the bug this parameter exists to prevent.
    public static func plan(track: String, artist: String, regionWidth: CGFloat,
                            fraction: Double, available: CGFloat?, pin pinned: Rung?,
                            settings: Settings, metrics: Rung.Metrics,
                            measure: (String) -> CGFloat) -> Resolution {
        if let pinned {
            // A pin deliberately overrides the budget AND the measurement: the user is
            // overruling the safety margin, and capping it here would make the Display
            // submenu a hint rather than a setting. This is the one path that can still
            // displace a neighbour.
            return pin(pinned, track: track, artist: artist, regionWidth: regionWidth,
                       settings: settings, metrics: metrics, measure: measure)
        }
        var b = budget(regionWidth: regionWidth, fraction: fraction, metrics: metrics)
        if let available {
            // Floored at the smallest rung: the item must always render something, even
            // when there is genuinely no room.
            b = max(min(b, available), Rung.playPause.chromeWidth(metrics))
        }
        return resolve(track: track, artist: artist, budget: b,
                       settings: settings, metrics: metrics, measure: measure)
    }
```

- [ ] **Step 4: Update the two call sites in `relayout`**

In `Sources/SpotifyMenuBar/main.swift`, `relayout(track:artist:)` calls `BarLayout.plan` twice — once in the empty-track guard, once on the normal path. Add `available: measuredAvailable(),` after `fraction: fraction,` in **both**. (Task 4 replaces this with a single hoisted value; passing it twice here is correct for now.)

- [ ] **Step 5: Run the checks to verify they pass**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `93/93 checks passed`, exit 0 (89 + 4).

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/
git commit -m "fix(layout): cap the automatic budget at measured free space

A fixed fraction of the region is a guess. Measured on a notched display, the
item requested 205pt when only 196pt was free and macOS hid a neighbouring
app's icon. The measurement is now a harder ceiling than the fraction; a
pinned rung stays exempt by design."
```

---

### Task 4: Start minimal, then grow

The first layout cannot measure — our window is not yet committed to the window server. Rendering the smallest rung until it can is what keeps the eviction bug off the launch path.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (`relayout`; new `scheduleMeasureRetry`; two new properties)

**Interfaces:**
- Consumes: `measuredAvailable()` (Task 2), `BarLayout.plan(…available:…)` (Task 3), `lastTrack`, `relayout`.
- Produces: `private var measureRetryPending: Bool`, `private var measureRetries: Int`, `func scheduleMeasureRetry()`

- [ ] **Step 1: Add the retry state and scheduler**

Add to `AppDelegate`'s property block:

```swift
    // Bounded grow-in state. The first layout after launch cannot measure free space
    // because our window is not yet committed to the window server.
    private var measureRetryPending = false
    private var measureRetries = 0
```

Add this method next to `relayout`:

```swift
    /// One bounded re-layout once the window server has placed our item.
    ///
    /// Not a loop: `available` is invariant to our own width, so the first measured
    /// layout is already final. The retry cap exists only for the pathological case
    /// where the window is never placed — without it, a permanently nil measurement
    /// would reschedule every runloop turn forever.
    func scheduleMeasureRetry() {
        guard !measureRetryPending, measureRetries < 5 else { return }
        measureRetryPending = true
        measureRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.measureRetryPending = false
            self.relayout(track: self.lastTrack.track, artist: self.lastTrack.artist)
        }
    }
```

- [ ] **Step 2: Hoist the measurement in `relayout` and start minimal**

In `relayout(track:artist:)`, replace the four hoisted locals (`settings`, `metrics`, `regionWidth`, `fraction`) block by adding the measurement immediately after `let fraction = Settings.maxWidthFraction()`:

```swift
        // Not yet placed: fall back to the smallest rung, which can never be too wide,
        // and retry once the window server has positioned us. Starting from the fraction
        // instead would put the eviction bug on the launch path — the reported symptom.
        let measured = measuredAvailable()
        if measured == nil {
            scheduleMeasureRetry()
        } else {
            measureRetries = 0   // a successful measurement re-arms the budget for later
        }
        let available = measured ?? Rung.playPause.chromeWidth(metrics)
```

Then change **both** `BarLayout.plan` call sites from `available: measuredAvailable(),` to `available: available,` so the value is measured once per layout rather than twice.

- [ ] **Step 3: Verify build and that nothing regressed**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `93/93 checks passed`, exit 0 (unchanged; this task is AppKit-only).

- [ ] **Step 4: Human verification — this is where the reported bug is fixed**

Do **not** attempt this yourself; it requires launching the GUI app. Write these steps into your report and hand off:

1. `./build-app.sh`, replace `/Applications/SpotifyMenuBar.app`, and quit the running copy first.
2. `defaults write com.local.SpotifyMenuBar debugLayout -bool YES`
3. Crowd the menu bar until it is nearly full (open menu-bar apps, and/or turn on extra Control Center items and the clock's date + seconds).
4. Launch the app. **Confirm no existing menu-bar icon disappears.** This is the check that matters.
5. Read `/usr/bin/log stream --predicate 'subsystem == "com.local.SpotifyMenuBar"' --info` and confirm two things: an early line with `available=nil` at `rung=playPause`, then a later line with a real `available=` value at a larger rung — the grow-in.
6. Confirm `requested=` never exceeds `available=` on any line where `available=` is not `nil`.
7. Note whether the launch grow-in is visually objectionable.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat(menubar): start at the smallest rung until free space is measurable"
```

---

### Task 5: Re-measure when the bar's contents change

Another app launching or quitting is when status items actually appear and disappear. These need their own coalescing.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (`applicationDidFinishLaunching`; new `barContentsMaybeChanged`; one new property)

**Interfaces:**
- Consumes: `relayout`, `lastTrack` (existing).
- Produces: `private var pendingMeasure: DispatchWorkItem?`, `@objc func barContentsMaybeChanged()`

- [ ] **Step 1: Add the coalesced handler**

Add to `AppDelegate`'s property block:

```swift
    // Coalesced separately from `pendingRefresh`: sharing one work item would let a track
    // change cancel a pending measurement, or the reverse.
    private var pendingMeasure: DispatchWorkItem?
```

Add the handler next to `screenChanged()`:

```swift
    /// Another app launching or quitting is when menu-bar items actually come and go.
    /// Debounced because login items and Space switches deliver these in bursts.
    @objc func barContentsMaybeChanged() {
        pendingMeasure?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.relayout(track: self.lastTrack.track, artist: self.lastTrack.artist)
        }
        pendingMeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
```

- [ ] **Step 2: Register the observers**

In `applicationDidFinishLaunching`, immediately after the existing `NSWorkspace.shared.notificationCenter.addObserver(...)` call for `activeSpaceDidChangeNotification`:

```swift
        // NSWorkspace notifications only post on NSWorkspace's own centre — registering
        // these on `.default` would silently never fire.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(barContentsMaybeChanged), name: name, object: nil)
        }
```

- [ ] **Step 3: Verify build and that nothing regressed**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `93/93 checks passed`, exit 0.

- [ ] **Step 4: Human verification**

Hand off, do not attempt: with `debugLayout` on and the app running on a nearly-full bar, quit another menu-bar app and confirm a new `[layout]` line appears within about a second with a **larger** `available=`; launch it again and confirm `available=` shrinks and the rung steps down if needed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat(menubar): re-measure free space when apps launch or quit"
```

---

### Task 6: Documentation

**Files:**
- Modify: `AGENTS.md` (new decision 19; amend decision 14)
- Modify: `README.md` (space behavior; narrow the known limitation)

- [ ] **Step 1: Add decision 19 to `AGENTS.md`**

Append to the "Hard-won design decisions — do not regress these" list:

```markdown
19. **The automatic path must never exceed measured free space.** `BarLayout.availableWidth`
    reads every status item's geometry via `CGWindowListCopyWindowInfo` and
    `BarLayout.plan` caps the budget at it. Before this, a fixed 0.25 fraction asked for
    205pt when only 196pt was free and macOS hid a neighbouring app's icon (NordVPN's,
    measured 2026-08-19). Two properties keep it safe and must survive any refactor:
    `own` is included in `all`, which makes `available` **invariant to our own width** and
    is the only reason the grow-in terminates without hysteresis; and free space is derived
    from the occupied block's **left edge**, not a sum of widths, because items can overhang
    the region (one ended 2pt past `region.maxX`). Identify our own window by
    taking our own rect from `NSWindow.frame` and using `CGWindowList` only for other
    items' `minX` — **our own item is unfindable in that list**, because macOS hosts
    NSStatusItem windows in the Control Center process, so every entry carries Control
    Center's pid and window number. Only `X` and `width` are comparable anyway
    (`CGWindowBounds` is top-left origin, `NSWindow.frame` bottom-left). `CGWindowList`
    bounds need no
    Screen Recording permission; only window *titles* do. A **pinned** rung is the
    deliberate exception and stays exempt.
```

- [ ] **Step 2: Amend decision 14**

Decision 14 currently describes `maxWidthFraction` as the ceiling. Add one sentence: the fraction is now the *softer* of two ceilings, with measured free space (decision 19) the harder one, and the automatic path takes the smaller.

- [ ] **Step 3: Update `README.md`**

In the adaptive-layout Features bullet, say the item measures how much menu-bar space is actually free rather than assuming a fixed share, so it will not push other icons out.

Then narrow the known limitation. It currently says macOS may still hide the item on a crowded bar; that now applies only to a **pinned** layout. Replace it with: the automatic layout measures free space and will not displace other icons, but a layout pinned via **Display** deliberately overrides that, so a pinned larger layout can still be hidden — pick a smaller one or **Auto**.

- [ ] **Step 4: Verify nothing is stale**

Run: `grep -n "fixed share\|0.25 of the region\|may still hide" README.md AGENTS.md`
Expected: no hit that still presents the fraction as the only ceiling, or the eviction caveat as applying to the automatic path.

Run: `swift build && swift run SpotifyMenuBarCoreTests`
Expected: `Build complete!` and `93/93 checks passed`.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md README.md
git commit -m "docs: document measured free space as the harder ceiling"
```

---

## Self-Review

**Spec coverage** — every section maps to a task:

| Spec section | Task |
|---|---|
| Problem / the 205-vs-196 measurement | Task 3 (the cap is the fix) |
| Key finding: `CGWindowList` needs no permission | Task 2 |
| Own rect from `NSWindow.frame`; never look ourselves up in `CGWindowList` | Task 2 Step 1, `AGENTS.md` 19 in Task 6 |
| Window must be committed before it is listed | Task 2 (nil return), Task 4 (grow-in) |
| 1. Measurement (AppKit) | Task 2 |
| 2. Arithmetic (pure, Core) | Task 1 |
| 3. Why it cannot oscillate | Task 1's stability sweep; `scheduleMeasureRetry` comment in Task 4 |
| 4. Budget composition | Task 3 |
| 5. Startup: start minimal, then grow | Task 4 |
| 6. Re-measure triggers + own coalescing | Task 5 |
| 7. Pin is exempt | Task 3 Step 3, checked in Task 3 Step 1 |
| Structure / boundaries | Tasks 1–2 (Core vs AppKit split) |
| Failure-mode table | Task 2 (nil paths), Task 3 (`available` nil, floor), Task 1 (clamp at 0, empty list) |
| Settings: `debugLayout` gains `available=` | Task 2 Step 2 |
| Verification table | each task's verify step; Task 4 Step 4 is the one that matters |
| Docs to update | Task 6 |

No gaps.

**Placeholder scan:** no "TBD", "TODO", "handle edge cases", or "similar to Task N". Every code step carries real code.

**Type consistency:** `availableWidth(own:all:region:)` keeps one signature across Tasks 1, 2 and `AGENTS.md`. `plan(...)` gains `available: CGFloat?` in Task 3 and every later reference uses it. `measuredAvailable() -> CGFloat?` is introduced in Task 2 and used in Tasks 3 and 4. `pendingMeasure` is deliberately distinct from the existing `pendingRefresh`.

**Known sequencing wrinkle:** Task 3 Step 4 wires `available: measuredAvailable()` at both call sites, and Task 4 Step 2 replaces both with a single hoisted `available`. That is intentional — Task 3 must leave the build green on its own — but the Task 4 implementer should expect to edit lines Task 3 just wrote.

**Verified numbers:** every expected value in Tasks 1 and 3 was produced by running a prototype of `availableWidth` and of the amended `plan` against the 7pt-per-character stub, not derived by hand. The stability sweep was confirmed to yield exactly one distinct value (196) across widths 24–400.
