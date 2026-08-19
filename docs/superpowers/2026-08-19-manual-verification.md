# Manual verification — menu-bar space adaptation

Everything in this branch that a machine could check is checked: `swift build` is clean
and `swift run SpotifyMenuBarCoreTests` reports 83/83. What remains needs a human at the
keyboard, because the agent session may not launch a GUI app.

Two kinds of item below:

- **Verification** (sections 1–3) — confirming shipped behavior. If one of these fails,
  it is a bug to fix.
- **A probe** (section 4) — a measurement whose *result* decides whether a further
  feature is buildable at all. "Nothing moved" is a valid, useful answer.

Spec: `docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md`
Plan: `docs/superpowers/plans/2026-08-18-menu-bar-space-adaptation.md`

---

## 1. Width budget and the rung ladder


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
   This is the check that actually falsifies the original bug; the
   floor-forcing checks below only exercise degradation mechanics.
3. **Small-fraction degradation, display-dependent — read the formula, not
   just "icons".** Run
   `defaults write com.local.SpotifyMenuBar maxWidthFraction -float 0.08`
   then change track. `0.08` clamps to `0.10`. What rung this produces
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
   and the item does not disappear.
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
9. **`playPause` rung / menu fallback — cannot be verified yet, say so
   plainly.** Because `maxWidthFraction` clamps at a floor of `0.10`,
   reaching a budget below 68pt (the `icons` floor) needs a screen narrower
   than roughly 1360pt — not achievable via this setting on a normal
   display. So `menuPrevItem`/`menuNextItem` (and the separator fixed in
   F4) are **not exercised by any of the steps above** and remain
   unverified until Task 7's feedback-driven demotion can actually reach
   the floor. Do not report this rung as checked.

Do not proceed past this point until a human confirms all nine checks (or
explicitly defers #9 per its own note).

---

## 2. Re-layout on display and Space changes


To verify this task works correctly:

1. **Build the app:**
   ```bash
   swift build
   ```

2. **Rebuild and launch** (in an interactive session where you can run the GUI):
   - Build the app: `swift build`
   - Note: Do not use `swift run` directly in non-interactive sessions. In an interactive macOS session, you would need to run it from the built product.

3. **Test display docking/undocking:**
   - Start Spotify and play a track
   - Launch Spotify Menu Bar (the built app)
   - Observe the current menu-bar layout (should show track name with buttons depending on available width)
   - **Dock or undock an external display** (or use System Preferences to simulate a display configuration change)
   - Without any track change in Spotify, observe that the menu-bar item **immediately resizes** to fit the new screen region
   - Verify that it properly degrades through the layout rungs (full → artist-omitted → icon-only) based on available width, or upgrades to full layout if more space is available

4. **Test Space switching:**
   - In the same setup, switch to a different Space (Mission Control or using keyboard shortcuts)
   - Observe that the menu-bar item re-evaluates and resizes appropriately for the new Space

5. **Confirm recovery:**
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

## 4. THE PROBE — is clip detection implementable at all?

This is the blocking unknown. macOS exposes no API for remaining menu-bar space, and it
is undocumented which observable field changes when it clips a status item. The shipped
app already works without this: it never requests more than its budget. What the probe
decides is whether a *corrective* loop — noticing the bar is crowded by other apps' items
and stepping down a rung in response — can be built.

**"None of the three fields moved" is a complete and useful result.** It means clip
detection is not implementable on this macOS version, the feature stays as it is
(computed ceiling only), and `AGENTS.md` decision 16 already records that as the final
state. Do not treat it as a failure.


### 1. Build and install

```
./build-app.sh
```

Then replace the installed copy and relaunch:

```
rm -rf /Applications/SpotifyMenuBar.app
mv SpotifyMenuBar.app /Applications/
open /Applications/SpotifyMenuBar.app
```

(Adjust paths if `build-app.sh` emits the `.app` somewhere other than the repo root —
check its output.)

### 2. Turn the diagnostic on

```
defaults write com.local.SpotifyMenuBar debugLayout -bool YES
```

Relaunch the app after setting this (`UserDefaults` is read at each `apply` call, but a
fresh launch guarantees a clean log from the start).

### 3. Read the log

```
log stream --predicate 'eventMessage CONTAINS "[layout]"' --info
```

(Console.app with a search filter of `[layout]` works identically if preferred.)

Each line looks like:

```
[layout] rung=full text=Some Track requested=210.0 length=210.0 region={{0, 0}, {1440, 24}} visible=Y windowFrame={{1200, 0}, {210, 24}}
```

### 4. Force a healthy baseline

With the bar otherwise uncrowded, play/change a track (or trigger any `relayout`) and
capture one or two `[layout]` lines. This is the reference state everything else is
compared against.

### 5. Force clipping — at least two ways

**A. Crowd the bar with other apps' status items.** Launch several menu-bar apps (or
increase an existing one's width — e.g. an app that shows a live text ticker) until
there is no room left for this item. macOS clips items right-to-left as space runs out,
so keep adding until the Spotify item either shrinks unexpectedly, disappears, or the
system menu overflow indicator (»)/Bartender-style behavior kicks in.

**B. Make this item greedy on purpose.**

```
defaults write com.local.SpotifyMenuBar maxWidthFraction -float 1.0
```

Relaunch, then trigger a `relayout` (change track). This inflates the computed budget
toward the full width of the screen, which should force macOS to clip or hide the item
even without other apps competing for space — a repeatable, single-machine way to
provoke the same condition as (A).

Capture `[layout]` lines in this crowded/greedy state.

### 6. Compare the two states — exactly these three fields

| Field | Healthy expectation | What clipping might do |
|---|---|---|
| `visible=` | `Y` | Flips to `N` if macOS fully hides the item |
| `windowFrame` width vs. `length=` | equal (or windowFrame ≥ length) | windowFrame width smaller than the requested `length` if macOS granted less space than asked |
| `windowFrame` origin vs. `region=` | windowFrame origin is at or right of `region`'s `minX` | windowFrame origin pushed left of `region.minX` if the item was shifted/squeezed |

Report which of these three differ between the healthy and the crowded/greedy capture,
and by how much (paste the actual log lines, not a paraphrase).

### 7. Turn the diagnostic back off

```
defaults write com.local.SpotifyMenuBar debugLayout -bool NO
```

(Optionally also revert the greedy test key if it was set:
`defaults write com.local.SpotifyMenuBar maxWidthFraction -float <previous-value>`, or
`defaults delete com.local.SpotifyMenuBar maxWidthFraction` to fall back to its default.)

### A valid result is "nothing moved"

**If none of the three fields differ between the healthy and clipped captures, that is a
legitimate, useful result — not a failed probe.** It means macOS gives no observable
signal when it clips this status item on the tested OS version, so `clipVerdict()` in
Step 3 should be implemented as `.unknown` unconditionally (with a comment recording what
was tested), and the feature ships on the computed budget/ceiling alone — which the
existing design (Tasks 1–6) already handles without this feedback loop. Report the null
result plainly; do not read it as something having gone wrong.


---

## Known not verified

- The `playPause` rung and its right-click prev/next fallback. `maxWidthFraction` clamps
  at 0.10, so reaching a budget below the 68pt `icons` floor needs a screen narrower than
  ~1360pt. Unreachable by any setting on a normal display, so those menu items and the
  separator fix are untested until a demotion path can reach the floor.
