# Manual verification — menu-bar space adaptation

Everything in this branch that a machine could check is checked: `swift build` is clean
and `swift run SpotifyMenuBarCoreTests` reports 97/97. What remains needs a human at the
keyboard, because the agent session may not launch a GUI app.

**Start with section 5.1** — it is the headline acceptance test and the only check that
falsifies the reported bug directly. Sections 1–3 exercise mechanics beneath it.

Three kinds of item below:

- **Verification** (sections 1–3, 5) — confirming shipped behavior. If one of these fails,
  it is a bug to fix.
- **A probe** (section 4) — **already answered**, kept as the record. Nothing to run
  there.
- **Judgement calls** (5.4) — no right answer; your preference decides.

Two design→plan cycles are covered:

| | Spec | Plan |
|---|---|---|
| Rung ladder, fixed fraction | `docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md` | `docs/superpowers/plans/2026-08-18-menu-bar-space-adaptation.md` |
| Measured ceiling (supersedes the fraction as the binding cap) | `docs/superpowers/specs/2026-08-19-measured-free-space-design.md` | `docs/superpowers/plans/2026-08-19-measured-free-space.md` |

---

## 1. Width budget and the rung ladder

**Run every check in this section on a ROOMY bar** (few other menu-bar icons). Since the
second cycle, `BarLayout.plan` takes `max(min(fractionBudget, measuredCeiling), 24)`, so
the *measured ceiling* is the binding cap whenever the bar is crowded. On a crowded bar
these steps land on a **lower** rung than the arithmetic below predicts — that is the
ceiling working, not a failure. Section 5.1 is the mirror image: it deliberately crowds
the bar.

The original handoff only forced degradation via a tiny `maxWidthFraction`,
which tests the floor, not the reported bug (a long title evicting neighbours
at the *default* fraction), and it never exercised accessibility or the
`playPause` menu fallback. Replacing it in full:

1. **Baseline, default settings.** Run `./build-app.sh`, replace
   `/Applications/SpotifyMenuBar.app`, launch it, with Spotify playing a
   normal-length track. Confirm the item shows track and artist as before on
   a roomy bar.
2. **Exercise the actual reported bug (not just the floor).** At default
   `maxWidthFraction` (i.e. without writing the default), set
   `defaults write com.local.SpotifyMenuBar maxTrack -int 60` (or play a
   track with a very long title/artist), then change track. Confirm the
   item's width stays at roughly ≤ 0.25 × the status-item region — on the
   built-in notched display that's ~193pt (772pt region) — and, critically,
   that **no neighbouring menu-bar icon disappears or gets pushed off**.
   Treat ~193pt as an upper bound only: the measured ceiling can hold the item
   well below it, and did in testing (settled `length=175`, ceiling 183pt).
   Section 5.1 is now the primary check that falsifies the original bug — it
   tests the cap that actually binds; this step tests the softer fraction cap,
   and the floor-forcing checks below only exercise degradation mechanics.
3. **Small-fraction degradation, display-dependent — read the formula, not
   just "icons".** Run
   `defaults write com.local.SpotifyMenuBar maxWidthFraction -float 0.08`
   then change track. `0.08` clamps to `0.10` (`Settings.maxWidthFraction`
   clamps to `[0.10, 1.0]`). What rung this produces
   depends on the screen: region width × 0.10 is the budget, and
   `budget - 74 >= 40` (i.e. budget ≥ 114) keeps a label (`compact`), while
   `68 <= budget < 114` gives `icons`, and `budget < 68` gives `playPause`.
   On the **built-in notched display** (~772pt region → ~77pt budget) this
   lands on **icons**. On a **2560pt-wide external display** (region ~1280pt
   → ~128pt budget) it correctly stays at **compact** with an ellipsis —
   that is a pass, not a regression, so don't read it as a failure. State
   which display you're testing on when reporting the result.
4. **Absurd-small fraction still clamps, never vanishes.** Run
   `defaults write com.local.SpotifyMenuBar maxWidthFraction -float 0.03`.
   Confirm it also clamps to 0.10 (same result as step 3 for your display)
   and the item does not disappear. Both this step and step 3 assume the
   measured ceiling is the *looser* of the two caps — true on a roomy bar,
   false on a crowded one.
5. **Restore default.** Run
   `defaults delete com.local.SpotifyMenuBar maxWidthFraction`. Confirm
   normal width returns.
6. **Tooltip survives icon-only degradation.** At whichever step above
   produced the `icons` rung, hover the item and confirm the tooltip still
   shows the full "Track – Artist" text (or bare "Track" if the artist is
   empty, e.g. an ad).
7. **First-glyph clipping (F2 regression check).** At the `full` rung
   (default settings, normal track), visually confirm the label's first
   character is neither clipped nor touching the item's left edge — this is
   the symptom F2's under-measurement produced.
8. **VoiceOver at the icons rung (new — was previously unchecked).** With
   VoiceOver on, focus the status item at the `icons` rung (from step 3) and
   confirm it announces the full "Track – Artist", not just "Spotify" or
   silence — this exercises `host?.setAccessibilityLabel(...)`, the only
   thing announcing the track once the label is hidden.
9. **`playPause` rung / menu fallback — reachable two ways now.** It is true
   that `maxWidthFraction` alone cannot get there: it clamps at `0.10`, so a
   budget below the 68pt `icons` floor would need a screen narrower than
   roughly 1360pt. But the rung is no longer stranded, and the route this step
   originally waited on is gone — Task 7's feedback-driven demotion was closed
   **won't-build** (section 4, `AGENTS.md` decision 16). Reach it by either:
   - **right-click → Display → Play/Pause Only**, which pins the rung
     directly (also covered by section 3); or
   - **crowding the bar** so the measured ceiling falls below 68pt — the
     automatic path, and what section 5.1 expects to see.

   At that rung, confirm `menuPrevItem`/`menuNextItem` and their separator
   (fixed in F4) appear in the right-click menu. This rung **can** be reported
   as checked.

Do not proceed past this point until a human confirms all nine checks.

---

## 2. Re-layout on display and Space changes


To verify this task works correctly:

1. **Build and install**, exactly as in section 1 step 1 and section 5.1:
   ```bash
   ./build-app.sh
   ```
   Quit the running copy, replace `/Applications/SpotifyMenuBar.app`, launch that.
   **Never `swift run SpotifyMenuBar`** — it blocks on a foreground GUI app.

2. **Test display docking/undocking:**
   - Start Spotify and play a track
   - Launch Spotify Menu Bar (the built app)
   - Observe the current menu-bar layout (should show track name with buttons depending on available width)
   - **Dock or undock an external display** (or use System Preferences to simulate a display configuration change)
   - Without any track change in Spotify, observe that the menu-bar item resizes to fit the new screen region. Expect **two** movements, not one: an immediate relayout for the new region, then — because `screenChanged` clears the cached ceiling when the region actually moves — a shrink to minimum and a regrow into the freshly measured ceiling
   - Verify it degrades through the ladder (`full` → `compact` → `icons` → `playPause`) as width falls, and climbs back when more space is available

3. **Test Space switching:**
   - In the same setup, switch to a different Space (Mission Control or using keyboard shortcuts)
   - Observe that the menu-bar item re-evaluates and resizes appropriately for the new Space

   - A Space switch shares the same selector but never moves the region, so the ceiling is *kept*; you should still see one remeasure blink, deferred if it lands inside the ~3s rate-limit window

4. **Confirm recovery:**
   - Return to the original Space or display configuration
   - The item should recover to its appropriate layout for that region's width


---

## 3. The Display submenu (pinning a rung)

**Step 9 — human verification (handed off, not performed by me).**
I did not launch or screenshot the app (per constraint). Please:
1. `swift build`, then launch the built `SpotifyMenuBar` binary yourself
   (do not use `swift run SpotifyMenuBar`).
2. Right-click the menu-bar item and confirm a `Display` submenu appears with five
   entries: Auto, Track and Artist, Track Only, Controls Only, Play/Pause Only.
3. Pick each entry in turn and confirm the menu-bar item's layout changes
   immediately to match (Track and Artist → full; Track Only → compact;
   Controls Only → icons only; Play/Pause Only → play/pause only).
4. Reopen the menu after each pick and confirm the checkmark tracks the current
   choice.
5. Pick `Auto` and confirm budget-driven behavior resumes (layout responds to
   window/screen space again rather than staying pinned).
6. Quit and relaunch the app; confirm the previously chosen mode is still in effect
   and still checked (it's stored in `UserDefaults.standard` under `"displayMode"`,
   so it persists across launches).


Appended to the Step 9 handoff (in addition to the six scenarios already listed
above):

7. **Pin + empty artist:** pin "Track and Artist", then let a Spotify **ad** play
   (or play an untagged local file). Confirm the label reads just the title with
   **no trailing dash** — this is the scenario F1 found broken and this fix round
   closes.
8. **Pin + Spotify closed:** pick a non-Auto mode, then **quit Spotify**. Confirm the
   "♪" placeholder honours the pinned rung rather than reverting to the automatic
   choice — this is the specific bug the original brief's Step 6 was written to
   prevent, and nothing before this fix round checked it end-to-end.


---

## 4. The probe — ANSWERED 2026-08-19, nothing left to run

Ran on the built-in notched display. **Result: clip detection is not implementable, and
the design targeted the wrong failure mode.** Do not re-run this section; it is kept as
the record.

With the bar crowded, launching the app evicted a neighbouring icon (NordVPN's). At that
moment our item logged:

```
rung=compact requested=193.0 length=188.5 visible=Y
region={{956,1085},{772,32}}  windowFrame={{0,-33},{205,33}}
```

All three candidate predicates reported **healthy**, and correctly so: we asked for
188.5pt (24% of the 772pt region), were granted it, and stayed visible. NordVPN's process
was still alive — its icon was hidden, not its app. **We were not the clipped party; we
were the cause.** `clipVerdict` watches our own window, so it could never have fired in
the scenario it was written for.

Being modest did not help either: an eviction happened while we were inside budget,
because the bar had less than 188.5pt free, and macOS offers no way to ask how much room
remains before claiming some.

Full measurements, the healthy-baseline samples, and the one usable signal the probe did
surface (the `windowFrame.minX − region.minX` headroom gap) are in
`docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md` section 5.
`AGENTS.md` decision 16 records the outcome as final.

Two incidental findings worth keeping:

- **`NSLog` is unusable for diagnostics.** Current macOS redacts its formatted string to
  `<private>` in the unified log — the original probe instructions could never have been
  read. `logLayout` now uses `os.Logger` with `privacy: .public` per value. Read it with
  `/usr/bin/log stream --predicate 'subsystem == "com.local.SpotifyMenuBar"' --info`
  (absolute path: `log` may be shadowed by a shell builtin).
- **`maxWidthFraction -float 1.0` cannot force clipping.** Label length is bounded by real
  track metadata, not config; the item topped out at 351pt and stayed visible. Only
  crowding the bar with other apps reproduces it.

### Turning the diagnostic off

```
defaults delete com.local.SpotifyMenuBar debugLayout
```

## Coverage gaps — closed

This section used to record the `playPause` rung and its right-click prev/next fallback as
unreachable, on the assumption that the abandoned demotion loop was the only route to them.
Two routes exist now — the **Display** pin and a crowded-bar measured ceiling — so the gap
is closed and the checks live in section 1 step 9 and section 3. Nothing is knowingly
unreachable; what remains is simply the human checks in sections 1–3 and 5.

---

## 5. Measured free space (added 2026-08-19, second plan)

The status item now caps itself at the free space it can actually measure, instead of a
fixed 25% of the region. Everything machine-checkable is checked (97/97), and I verified the
mechanism at runtime by reading the unified log. **One thing was never directly observed and
needs you: the headline acceptance test.**

### 5.1 The check that matters — never displace a neighbour

1. `./build-app.sh`, quit the running copy, replace `/Applications/SpotifyMenuBar.app`.
2. `defaults write com.local.SpotifyMenuBar debugLayout -bool YES`
3. `defaults delete com.local.SpotifyMenuBar displayMode` — a pin deliberately bypasses the
   whole mechanism, so any pinned mode invalidates this test.
4. Crowd the menu bar until it is nearly full.
5. Launch the app. **Confirm no existing menu-bar icon disappears.**

Expect the item to settle **small** — controls-only or play/pause-only. That is the honest
cost of never evicting anyone, not a bug. `Display` overrides it if you would rather have the
width, and that override is the one remaining path that can still displace something.

### 5.2 Read the log

```
/usr/bin/log stream --predicate 'subsystem == "com.local.SpotifyMenuBar"' --info
```

The absolute path matters — `log` is commonly shadowed by a shell builtin, which silently
returns nothing.

Two fields to distinguish:

- **`ceiling=`** is the cached value actually driving the budget. Measured only while the
  item is at its minimum width, because that is the only moment nothing has been evicted and
  the reading is honest.
- **`available=`** is a live reading. It legitimately moves with our own width — it read 91pt
  at 40pt wide and 437pt at 282pt wide on the same bar. **Do not** expect it to be stable.

### 5.3 What correct looks like

- **The cycle:** an early line at `rung=playPause` with `ceiling=nil`, then a line with a
  real `ceiling=`, then the settled rung.
- **No ratchet:** across several track changes, `ceiling=` holds the *same* number and the
  rung does not creep upward. Watch `ceiling=`, not `available=`.
- **The item fits:** the width component of `windowFrame=` should not exceed `ceiling`.
  The log prints the whole rect — `windowFrame={{x,y},{width,height}}` — so read the third
  number; there is no `windowW=` field to grep for. macOS grants a window 16pt wider than
  the requested `length`, and the ceiling is converted to account for it. Observed settled
  state was `length=175.0`, `windowFrame={{…},{191,33}}`, `ceiling=183.0`.
- **Bar changes are picked up:** quit another menu-bar app and one shrink-and-regrow should
  happen within a second or so, ending at a possibly larger rung. Rate-limited to about one
  per 3s.

### 5.4 Judgement calls for you

- **Is the blink acceptable?** Re-establishing the ceiling requires shrinking to minimum
  first. That happens at launch, on app launch/quit, and on screen or Space change — not on
  track changes. Launching or quitting an ordinary app with no menu-bar icon still costs one.
- **Is the item too small on your bar?** If never-evict costs more width than you want,
  raise it with `maxWidthFraction` (the softer ceiling) or pin a layout from **Display**.

### 5.5 Turning the diagnostic off

```
defaults delete com.local.SpotifyMenuBar debugLayout
```
