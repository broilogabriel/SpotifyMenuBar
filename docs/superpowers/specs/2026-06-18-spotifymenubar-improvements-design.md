# SpotifyMenuBar — improvements design

**Date:** 2026-06-18
**Status:** Approved (design); pending implementation plan
**Scope:** Code-quality + correctness + functionality improvements, including two
project-convention changes (Config enum, UserDefaults preferences). Stays a single
file per `AGENTS.md`.

## Goal

Improve `Sources/SpotifyMenuBar/main.swift` along three axes without regressing any
of the documented hard-won design decisions:

1. **Swift-idiomatic structure** — replace `SCREAMING_SNAKE_CASE` globals with a
   `Config` caseless enum and small focused types.
2. **Correctness & responsiveness** — move AppleScript off the main thread, coalesce
   notification bursts, fix the stale-display-when-Spotify-quits bug, and avoid the
   `tell application` auto-launch side effect for state detection.
3. **Functionality** — runtime-tunable settings via `UserDefaults` (no rebuild),
   accessibility labels, and a full-title tooltip.

## Non-goals (deferred)

- Album art, Apple Music support, a preferences *window*, configurable hotkeys.
- Developer-ID signing / notarization (remains ad-hoc, personal use).
- An XCTest target (verification stays "compiles + human run" per `AGENTS.md`).

## Architecture

Single file, organized with `// MARK:` sections: **Config / Settings**,
**SpotifyClient**, **AppDelegate**, **entry point**. Two new small types provide
idiomatic internal structure while preserving the single-file decision (cheap to
split later if the app keeps growing).

### Config — compile-time defaults

Replaces the `MAX_TRACK` / `MAX_ARTIST` / `PREV_RESTART_SECS` globals.

```swift
enum Config {
    static let maxTrack = 18
    static let maxArtist = 18
    static let prevRestartSecs = 3.0
    static let buttonWidth: CGFloat = 16   // was a magic number in control()
    static let stackSpacing: CGFloat = 6
}
```

Naming follows the Swift API Design Guidelines (lowerCamelCase). **This changes the
`AGENTS.md` UPPER_CASE convention** (see Docs section).

### Settings — runtime overrides, live re-read

Read fresh from `UserDefaults` on every `refresh()`, falling back to `Config` and
clamped to sane minimums so a bad value can't break layout.

```swift
struct Settings {
    let maxTrack: Int, maxArtist: Int, prevRestartSecs: Double
    static func current() -> Settings {
        let d = UserDefaults.standard
        func int(_ k: String, _ fb: Int) -> Int { max(1, d.object(forKey: k) as? Int ?? fb) }
        return Settings(
            maxTrack: int("maxTrack", Config.maxTrack),
            maxArtist: int("maxArtist", Config.maxArtist),
            prevRestartSecs: max(0, d.object(forKey: "prevRestartSecs") as? Double ?? Config.prevRestartSecs))
    }
}
```

- Keys: `maxTrack` (Int), `maxArtist` (Int), `prevRestartSecs` (Double).
- Absent key → compile-time default. Present → clamped (`maxTrack`/`maxArtist` ≥ 1,
  `prevRestartSecs` ≥ 0).
- Live re-read: changes via `defaults write` apply on the next playback change — no
  restart.
- `Settings.current()` and `trunc(_:_:)` stay pure/side-effect-free so a test target
  could be added later (not added now).

### SpotifyClient — AppleScript off the main thread

```swift
final class SpotifyClient {
    private let queue = DispatchQueue(label: "com.local.SpotifyMenuBar.applescript")

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    func run(_ body: String, then completion: ((String?) -> Void)? = nil) {
        queue.async {
            let result = Self.execute(body)
            if let completion { DispatchQueue.main.async { completion(result) } }
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

- **Serial** queue: `NSAppleScript` is not thread-safe, so every call runs on the
  same dedicated thread, off the main thread. Completions hop back to `.main`.
- `isRunning` uses **`NSWorkspace`**, not AppleScript — detecting Spotify's state
  must not trigger the `tell application "Spotify"` auto-launch side effect.

## Behavior / data flow

- **Launch** → build UI → register `PlaybackStateChanged` observer → initial
  `refresh()`.
- **Notification** → `changed()` **debounced ~100 ms** via a cancel/replace
  `DispatchWorkItem` to coalesce Spotify's notification bursts → `refresh()`.
- **`refresh()`** → if `!isRunning`: reset label to `♪`, clear tooltip, return (no
  AppleScript → no launch). Else: run the state query async; on completion update on
  main.
- **Buttons:**
  - **play/pause** always runs (launches Spotify as the deliberate "start" gesture).
  - **next / prev** are no-ops when `!isRunning`.
  - `prev()` keeps smart-previous, using `Settings.current().prevRestartSecs`.
- **Async ordering:** a button tap returns immediately; the follow-up `refresh()` and
  the `PlaybackStateChanged` notification both reconcile the icon/label, so a dropped
  command self-corrects on the next state event.

## Accessibility & tooltip

- `control(_:_:_:)` gains a label parameter carried by the SF Symbol image:
  `NSImage(systemSymbolName:accessibilityDescription:)` with "Previous",
  "Play or pause", "Next". The text field is already VoiceOver-readable.
- `update()` sets the untruncated title as the hover tooltip:
  `label.toolTip = track.isEmpty ? nil : "\(track) – \(artist)"`.

## Error handling

- AppleScript failures: `NSLog` + return `nil` (unchanged).
- `nil`/unparsable result or `!isRunning` → reset label to `♪`, clear tooltip (fixes
  stale display when Spotify quits).
- Invalid `UserDefaults` values → clamped in `Settings.current()`.

## Testing / verification

No XCTest target (per `AGENTS.md`). Verification:

- `swift build` compiles.
- Manual run (human): track change; Spotify quit → label resets to `♪`; relaunch →
  reappears; prev near vs. after threshold; `defaults write` re-read without restart;
  VoiceOver reads each button; right-click → Quit / Launch at Login still work.

## Docs & convention changes (part of the work)

- **`AGENTS.md`:**
  - Rewrite the `UPPER_CASE` tunables convention → "tunables live in the `Config`
    enum (camelCase); runtime overrides via `Settings` / `UserDefaults`."
  - Add to *Hard-won design decisions — do not regress*: (9) AppleScript on a serial
    queue off the main thread; (10) running-check via `NSWorkspace`, never `tell`
    (avoids auto-launch); (11) `PlaybackStateChanged` debounce; (12) accessibility
    labels on the icon buttons; (13) `UserDefaults` keys + clamping.
- **`README.md`:** replace the "edit constants + rebuild" config table with a
  `defaults write com.local.SpotifyMenuBar maxTrack 24` table (key, type, default,
  meaning) and note the live re-read.

## Risks

- `NSWorkspace` bundle-id check assumes `com.spotify.client`; correct for the
  standard Spotify desktop client (documented assumption).
- Debounce delay (~100 ms) trades a tiny latency for far fewer redundant Apple Events;
  tunable if it feels laggy.
- Moving AppleScript async means the play/pause icon flips on the async completion
  rather than synchronously — acceptable, and reconciled by the notification anyway.
