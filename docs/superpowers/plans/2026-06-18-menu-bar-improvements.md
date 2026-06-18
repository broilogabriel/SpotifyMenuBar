# SpotifyMenuBar Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SpotifyMenuBar more idiomatic, responsive, robust, and runtime-configurable without regressing any documented design decision.

**Architecture:** Stays a single file (`Sources/SpotifyMenuBar/main.swift`) organized with `// MARK:` sections. A `Config` enum holds compile-time defaults; a `Settings` struct reads `UserDefaults` overrides live; a `SpotifyClient` type runs AppleScript on a dedicated serial queue off the main thread and detects whether Spotify is running via `NSWorkspace`.

**Tech Stack:** Swift 5.9, AppKit, ServiceManagement, SwiftPM. No third-party dependencies. macOS 13+.

## Global Constraints

- **Single file:** all app code stays in `Sources/SpotifyMenuBar/main.swift` (per `AGENTS.md`).
- **No third-party dependencies. No SwiftUI.** Plain Swift + AppKit only.
- **No automated test suite / no XCTest target.** The automated gate per task is a clean `swift build`. Manual verification is run by a human — **never run `swift run` from a non-interactive context** (it launches a blocking GUI app).
- **No AI attribution anywhere** — no `Co-Authored-By`, no "Generated with Claude", in commits/PRs/comments/docs. Commits authored solely by the human.
- **Conventional Commits 1.0.0** for every commit: `<type>[scope]: <description>`, imperative, lower-case, no trailing period. Types: `feat`, `fix`, `build`, `chore`, `ci`, `docs`, `style`, `refactor`, `perf`, `test`.
- **Comment the *why*, not the *what*** — match the existing terse style.
- **Branch:** `feat/menu-bar-improvements` (already checked out; the design doc is already committed there).
- **AppleScript facts:** the `spotify` helper wraps its body in `tell application "Spotify" … end tell`. Verified verbs: `playpause`, `play`, `pause`, `next track`, `previous track`. Properties: `current track` (`name`, `artist`, `album`, `artwork`), `player state`, `player position`.
- Build command and expected output: `swift build` → `Build complete!` (under RTK proxy it may print `ok (build complete)`). A failing build prints `error:` lines.

---

### Task 1: Config enum + extract magic numbers

Replace the `SCREAMING_SNAKE_CASE` global constants with a Swift-idiomatic `Config` caseless enum, and pull the two layout magic numbers into it. No behavior change.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (the `── Config ──` block, `control(_:_:)`, `applicationDidFinishLaunching` stack spacing, `prev()`, `update()`)

**Interfaces:**
- Produces: `enum Config { static let maxTrack: Int; static let maxArtist: Int; static let prevRestartSecs: Double; static let buttonWidth: CGFloat; static let stackSpacing: CGFloat }`. All later tasks read tunables from `Config` (and, after Task 2, `Settings`).

- [ ] **Step 1: Replace the global constants block with the `Config` enum**

Replace lines 4–8 (the `// ── Config ──` block and the three `let` globals) with:

```swift
// MARK: - Config

/// Compile-time defaults. Runtime overrides come from `Settings` (UserDefaults).
enum Config {
    static let maxTrack = 18
    static let maxArtist = 18
    static let prevRestartSecs = 3.0   // within this many secs, "back" goes to the previous track; later it restarts
    static let buttonWidth: CGFloat = 16
    static let stackSpacing: CGFloat = 6
}
```

- [ ] **Step 2: Use `Config.stackSpacing` and `Config.buttonWidth`**

In `applicationDidFinishLaunching`, change `stack.spacing = 6` to:

```swift
        stack.spacing = Config.stackSpacing
```

In `control(_:_:)`, change `b.widthAnchor.constraint(equalToConstant: 16).isActive = true` to:

```swift
        b.widthAnchor.constraint(equalToConstant: Config.buttonWidth).isActive = true
```

- [ ] **Step 3: Update the constant references in `prev()` and `update()`**

In `prev()`, change `\(PREV_RESTART_SECS)` to `\(Config.prevRestartSecs)`:

```swift
    @objc func prev() {
        spotify("if player position > \(Config.prevRestartSecs) then\n" +
                "set player position to 0\n" +
                "else\n" +
                "previous track\n" +
                "end if")
        refresh()
    }
```

In `update(track:artist:state:)`, change the `trunc` calls:

```swift
        let title = "\(trunc(track, Config.maxTrack)) – \(trunc(artist, Config.maxArtist))"
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` (no `error:` lines).

- [ ] **Step 5: Manual verification (human)**

Run the app (`swift run`) and confirm the menu-bar item still shows the truncated `track – artist` and buttons are unchanged. Behavior must be identical to before.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "refactor: replace global constants with Config enum"
```

---

### Task 2: Settings struct + UserDefaults live re-read

Add a `Settings` struct read fresh from `UserDefaults` on each use, so the tunables can change at runtime via `defaults write` without a rebuild or restart.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (add `Settings` after `Config`; use it in `prev()` and `update()`)

**Interfaces:**
- Consumes: `Config.maxTrack`, `Config.maxArtist`, `Config.prevRestartSecs` (Task 1).
- Produces: `struct Settings { let maxTrack: Int; let maxArtist: Int; let prevRestartSecs: Double; static func current() -> Settings }`. UserDefaults keys: `maxTrack` (Int), `maxArtist` (Int), `prevRestartSecs` (Double). `current()` clamps `maxTrack`/`maxArtist` to ≥ 1 and `prevRestartSecs` to ≥ 0.

- [ ] **Step 1: Add the `Settings` struct directly below the `Config` enum**

```swift
/// Runtime-overridable tunables. Read fresh on every refresh so `defaults write`
/// takes effect on the next playback change — no restart. Values are clamped so a
/// bad write can't break layout.
struct Settings {
    let maxTrack: Int
    let maxArtist: Int
    let prevRestartSecs: Double

    static func current() -> Settings {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            max(1, d.object(forKey: key) as? Int ?? fallback)
        }
        return Settings(
            maxTrack: int("maxTrack", Config.maxTrack),
            maxArtist: int("maxArtist", Config.maxArtist),
            prevRestartSecs: max(0, d.object(forKey: "prevRestartSecs") as? Double ?? Config.prevRestartSecs))
    }
}
```

- [ ] **Step 2: Read `Settings.current()` in `prev()`**

```swift
    @objc func prev() {
        let threshold = Settings.current().prevRestartSecs
        spotify("if player position > \(threshold) then\n" +
                "set player position to 0\n" +
                "else\n" +
                "previous track\n" +
                "end if")
        refresh()
    }
```

- [ ] **Step 3: Read `Settings.current()` in `update()`**

```swift
    func update(track: String, artist: String, state: String) {
        let s = Settings.current()
        let title = "\(trunc(track, s.maxTrack)) – \(trunc(artist, s.maxArtist))"
        let playing = state.lowercased() == "playing"
        DispatchQueue.main.async {
            self.label.stringValue = track.isEmpty ? "♪" : title
            self.playButton.image = NSImage(
                systemSymbolName: playing ? "pause.fill" : "play.fill",
                accessibilityDescription: nil)
            self.stack.layoutSubtreeIfNeeded()
            self.statusItem.length = self.stack.fittingSize.width + 8
        }
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Manual verification (human)**

Run the app, then in a terminal: `defaults write com.local.SpotifyMenuBar maxTrack 30`. Change the track in Spotify (or play/pause) and confirm the title now allows ~30 chars before truncation. Reset with `defaults delete com.local.SpotifyMenuBar maxTrack`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat: add UserDefaults-tunable settings with live re-read"
```

---

### Task 3: SpotifyClient — off-main AppleScript, running-check, not-running behavior

Move AppleScript onto a dedicated serial queue (off the main thread), detect whether Spotify is running via `NSWorkspace` (no auto-launch), reset the display to `♪` when Spotify is down, and make next/prev no-ops while play/pause still launches Spotify.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (remove global `spotify(_:)`; add `SpotifyClient`; add `spotify` property; rewrite `prev/next/playPause/refresh/update`; add `reset()` and `resize()`)

**Interfaces:**
- Consumes: `Settings.current()` (Task 2).
- Produces:
  - `final class SpotifyClient { var isRunning: Bool; func run(_ body: String, then completion: ((String?) -> Void)?) }` — `run` executes off-main and delivers `completion` on the main thread.
  - `AppDelegate.reset()` — sets the placeholder display (`♪`, no tooltip, play icon) on the main thread.
  - `AppDelegate.resize()` — recomputes `statusItem.length` from the stack's fitting size.

- [ ] **Step 1: Remove the global `spotify(_:)` helper**

Delete the top-level `@discardableResult func spotify(_ body: String) -> String? { … }` function (its logic moves into `SpotifyClient.execute`).

- [ ] **Step 2: Add the `SpotifyClient` type above `AppDelegate`**

```swift
// MARK: - Spotify control

final class SpotifyClient {
    private let queue = DispatchQueue(label: "com.local.SpotifyMenuBar.applescript")

    /// Is the Spotify desktop app running? Checked via NSWorkspace so we never
    /// trigger the `tell application "Spotify"` auto-launch just to read state.
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    /// Runs AppleScript on a dedicated serial thread (NSAppleScript is not
    /// thread-safe) and delivers the result back on the main thread.
    func run(_ body: String, then completion: ((String?) -> Void)? = nil) {
        queue.async {
            let result = SpotifyClient.execute(body)
            if let completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private static func execute(_ body: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: "tell application \"Spotify\"\n\(body)\nend tell")?
            .executeAndReturnError(&err)
        if let err { NSLog("AppleScript error: \(err)"); return nil }
        return out?.stringValue
    }
}
```

- [ ] **Step 3: Add the `spotify` property to `AppDelegate`**

At the top of `AppDelegate`'s stored properties:

```swift
    let spotify = SpotifyClient()
```

- [ ] **Step 4: Rewrite the transport actions**

```swift
    // Smart previous: near the start → previous track; otherwise restart current
    // (so a second press from the restarted track also goes back).
    @objc func prev() {
        guard spotify.isRunning else { return }   // no-op when Spotify is closed
        let threshold = Settings.current().prevRestartSecs
        spotify.run("if player position > \(threshold) then\n" +
                    "set player position to 0\n" +
                    "else\n" +
                    "previous track\n" +
                    "end if") { [weak self] _ in self?.refresh() }
    }
    @objc func next() {
        guard spotify.isRunning else { return }   // no-op when Spotify is closed
        spotify.run("next track") { [weak self] _ in self?.refresh() }
    }
    @objc func playPause() {
        // Always allowed — launches Spotify as the deliberate "start" gesture.
        spotify.run("playpause") { [weak self] _ in self?.refresh() }
    }
```

- [ ] **Step 5: Rewrite `refresh()` to be async and reset when not running**

```swift
    func refresh() {
        guard spotify.isRunning else { reset(); return }
        spotify.run(
            "return (name of current track) & \"\\n\" & " +
            "(artist of current track) & \"\\n\" & (player state as string)"
        ) { [weak self] r in
            guard let self else { return }
            guard let r else { self.reset(); return }   // Spotify quit mid-query
            let p = r.components(separatedBy: "\n")
            if p.count == 3 { self.update(track: p[0], artist: p[1], state: p[2]) }
        }
    }

    /// Spotify unavailable → placeholder.
    func reset() {
        label.stringValue = "♪"
        label.toolTip = nil
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        resize()
    }
```

- [ ] **Step 6: Rewrite `update()` (runs on main via the completion) and add `resize()`**

```swift
    func update(track: String, artist: String, state: String) {
        let s = Settings.current()
        let title = "\(trunc(track, s.maxTrack)) – \(trunc(artist, s.maxArtist))"
        let playing = state.lowercased() == "playing"
        label.stringValue = track.isEmpty ? "♪" : title
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil)
        resize()
    }

    /// Resize the single status item to fit its content.
    func resize() {
        stack.layoutSubtreeIfNeeded()
        statusItem.length = stack.fittingSize.width + 8
    }
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 8: Manual verification (human)**

Run the app with Spotify playing — title/buttons work, UI never hangs while controls run. Quit Spotify → label resets to `♪`. With Spotify closed, click next/prev → nothing happens (Spotify does NOT launch). Click play → Spotify launches and starts. Relaunch Spotify and play → title reappears.

- [ ] **Step 9: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat: run AppleScript off the main thread and handle Spotify-not-running"
```

---

### Task 4: Debounce PlaybackStateChanged bursts

Coalesce Spotify's notification bursts into a single refresh ~100 ms later.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (add `pendingRefresh` property; rewrite `changed()`)

**Interfaces:**
- Consumes: `AppDelegate.refresh()` (Task 3).
- Produces: `private var pendingRefresh: DispatchWorkItem?` and a debounced `changed()`.

- [ ] **Step 1: Add the `pendingRefresh` property to `AppDelegate`**

Below the other stored properties:

```swift
    private var pendingRefresh: DispatchWorkItem?
```

- [ ] **Step 2: Rewrite `changed()` to debounce**

```swift
    // Coalesce PlaybackStateChanged bursts (Spotify fires several per change) into
    // a single refresh, cancelling any still-pending one.
    @objc func changed() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual verification (human)**

Run the app and skip rapidly through several tracks. The title should settle correctly on the final track without flicker or stale values.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "perf: debounce PlaybackStateChanged bursts into a single refresh"
```

---

### Task 5: Accessibility labels + full-title tooltip

Give the icon buttons VoiceOver labels and show the untruncated title on hover.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` (`control(_:_:_:)` signature + call sites; `update()` and `reset()` tooltip + play-button label)

**Interfaces:**
- Consumes: `AppDelegate.update()`, `reset()` (Task 3); `control(_:_:)` (Task 1).
- Produces: `control(_ symbol: String, _ label: String, _ action: Selector) -> NSButton` (now takes an accessibility label).

- [ ] **Step 1: Add a label parameter to `control(...)`**

```swift
    func control(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.contentTintColor = .labelColor
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: Config.buttonWidth).isActive = true
        return b
    }
```

- [ ] **Step 2: Pass labels at the three call sites in `applicationDidFinishLaunching`**

```swift
        let prev = control("backward.fill", "Previous", #selector(prev))
        playButton = control("play.fill", "Play or pause", #selector(playPause))
        let next = control("forward.fill", "Next", #selector(next))
```

- [ ] **Step 3: Add the tooltip + play-button label in `update()`**

```swift
    func update(track: String, artist: String, state: String) {
        let s = Settings.current()
        let title = "\(trunc(track, s.maxTrack)) – \(trunc(artist, s.maxArtist))"
        let playing = state.lowercased() == "playing"
        label.stringValue = track.isEmpty ? "♪" : title
        label.toolTip = track.isEmpty ? nil : "\(track) – \(artist)"   // full, untruncated
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: "Play or pause")
        resize()
    }
```

- [ ] **Step 4: Set the play-button label in `reset()`**

```swift
    func reset() {
        label.stringValue = "♪"
        label.toolTip = nil
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play or pause")
        resize()
    }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Manual verification (human)**

Run the app. Hover the title → tooltip shows the full untruncated `track – artist`. Enable VoiceOver (Cmd-F5) and navigate the buttons → it announces "Previous", "Play or pause", "Next".

- [ ] **Step 7: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat: add VoiceOver labels and a full-title tooltip"
```

---

### Task 6: Update docs (AGENTS.md + README.md)

Reflect the new conventions and the runtime settings.

**Files:**
- Modify: `AGENTS.md` (Conventions section; Hard-won design decisions)
- Modify: `README.md` (Configuration section)

**Interfaces:** none (documentation).

- [ ] **Step 1: Update the `AGENTS.md` "Conventions" tunables line**

Replace the line:
```
- Keep tunables as the `UPPER_CASE` constants in the `── Config ──` block at the top.
```
with:
```
- Tunables live in the `Config` caseless enum (lowerCamelCase, Swift-idiomatic).
  Runtime overrides are read from `UserDefaults` via `Settings.current()`.
```

- [ ] **Step 2: Append new entries to `AGENTS.md` "Hard-won design decisions — do not regress these"**

Add after item 8:
```
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
```

- [ ] **Step 3: Replace the `README.md` "Configuration" section**

Replace the existing "Configuration" section (the intro sentence + the constants table) with:

```markdown
## Configuration

Defaults live in the `Config` enum at the top of
`Sources/SpotifyMenuBar/main.swift`. You can override them at runtime — no
rebuild, no restart — with `defaults write`; changes apply on the next playback
change:

```bash
defaults write com.local.SpotifyMenuBar maxTrack -int 24
defaults write com.local.SpotifyMenuBar maxArtist -int 24
defaults write com.local.SpotifyMenuBar prevRestartSecs -float 2.5
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `maxTrack` | Int | `18` | Max characters of the track name before truncation (`…`) |
| `maxArtist` | Int | `18` | Max characters of the artist name |
| `prevRestartSecs` | Double | `3.0` | Below this playback position, "back" goes to the previous track; above it, "back" restarts the current track |

Remove an override with `defaults delete com.local.SpotifyMenuBar maxTrack`.
```

- [ ] **Step 4: Verify the docs build / render**

Run: `swift build`
Expected: `Build complete!` (docs don't affect the build; this confirms nothing in the tree broke).

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md README.md
git commit -m "docs: document Config/Settings, off-main AppleScript, and defaults keys"
```

---

## Self-Review

**Spec coverage:**
- Config enum → Task 1. ✅
- Settings / UserDefaults live re-read → Task 2. ✅
- SpotifyClient serial off-main queue + `isRunning` via NSWorkspace → Task 3. ✅
- Not-running behavior (reset to ♪; play launches; next/prev no-op) → Task 3. ✅
- Notification debounce → Task 4. ✅
- Accessibility labels + tooltip → Task 5. ✅
- Error handling (nil/unparsable → reset; clamping) → Tasks 2 & 3. ✅
- Docs & convention changes (AGENTS.md, README.md) → Task 6. ✅
- Out-of-scope items (album art, Apple Music, prefs window, notarization, XCTest) → intentionally not included. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step shows complete code.

**Type consistency:** `Config.*` names match across Tasks 1/3/5. `Settings.current()` signature matches Tasks 2/3/5. `SpotifyClient.run(_:then:)`, `isRunning`, `reset()`, `resize()` match between Tasks 3/4/5. `control(_:_:_:)` 3-arg form (Task 5) supersedes the 2-arg form (Task 1) and all call sites are updated in Task 5 Step 2.
