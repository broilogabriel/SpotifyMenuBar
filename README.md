# Spotify Menu Bar

A tiny macOS menu-bar controller for the **Spotify desktop app**. Shows the current
track and gives you transport controls directly in the menu bar — no popover, no
dock icon, ~0% idle CPU.

```
 Harder Better… – Daft Punk…  ⏮ ⏯ ⏭
```

It was built as a lightweight replacement for menu-bar Spotify controllers that
burn CPU by continuously re-rendering an animated/scrolling title. This app uses a
**static, truncated** title updated only on playback changes, so that whole class
of bug can't happen.

## Features

- Current **track – artist** in the menu bar, each truncated to a fixed width.
- Inline **previous / play-pause / next** buttons (no dropdown needed).
- **Smart previous:** within the first few seconds of a track, "back" jumps to the
  previous track; later in the track it restarts the current one (press again to go
  back) — standard player behavior.
- Play/pause icon reflects the real player state.
- **Adapts to the space available:** the item measures how much menu-bar space is
  actually free rather than assuming a fixed share, so it will not push other icons
  out. When the menu bar is tight, it steps down through track+artist → track only →
  controls only → play/pause alone instead of growing wide enough for macOS to hide
  it (or a neighbour). On a busy bar this means it will settle for controls-only or
  play/pause-only rather than displacing something — that's intended. Pin a specific
  layout from **right-click → Display** if you'd rather override that.
- **Right-click** for **Display** (pin a layout), **Launch at Login**, and **Quit**.
- Single menu-bar item, right-anchored, so it survives the MacBook **notch** and the
  buttons don't shift when the track text changes length.

## Requirements

- macOS 13 (Ventura) or later
- The **Spotify desktop app** installed (controls are sent to it locally)
- Swift toolchain (ships with Xcode or Command Line Tools) to build

No Spotify API key, OAuth, developer account, or network access is required.

## Build & run

```bash
cd ~/projects/SpotifyMenuBar
swift run
```

- On **first launch**, macOS shows a "…wants to control Spotify" prompt
  (Automation / Apple Events). Click **OK** — required for the controls to work.
- The item appears in your menu bar. It runs in the **foreground**; stop it with
  **Ctrl-C** in the terminal or **right-click → Quit**.
- `swift build` compiles without launching.

## Install as a launch-at-login app

To run it as a normal clickable app that starts automatically at login (no terminal):

```bash
./build-app.sh                          # produces SpotifyMenuBar.app (ad-hoc signed)
mv SpotifyMenuBar.app /Applications/     # recommended location for login items
open /Applications/SpotifyMenuBar.app
```

Then **right-click the menu-bar item → Launch at Login** to toggle it on (a
checkmark shows the current state). This uses Apple's `SMAppService` (macOS 13+);
the toggle also appears under **System Settings → General → Login Items**.

The same right-click menu has a **Display** submenu to pin how much the item shows:
**Auto** (the default — fits as much as the menu bar has room for), **Track and
Artist**, **Track Only**, **Controls Only**, or **Play/Pause Only**. The chosen mode
is checked in the submenu and persists across relaunches. Pinning a larger layout
overrides the space budget on purpose, so on a crowded menu bar macOS may still hide
the item — pick a smaller layout, or **Auto**, if that happens.

Notes:
- The `.app` is a menu-bar agent (`LSUIElement`) — no Dock icon, no app menu.
- It's **ad-hoc signed**, so it runs locally without notarization. Re-running
  `build-app.sh` re-signs it, which may re-trigger the one-time "control Spotify"
  consent prompt.

## Install with Homebrew

```bash
brew install broilogabriel/tap/spotifymenubar
ln -sfn "$(brew --prefix)/opt/spotifymenubar/SpotifyMenuBar.app" /Applications/SpotifyMenuBar.app
open /Applications/SpotifyMenuBar.app
```

The formula **builds from source** on your machine rather than downloading a
binary. That is deliberate: a locally compiled bundle never gets the
`com.apple.quarantine` attribute, so Gatekeeper never blocks it and the ad-hoc
signature is enough. A downloaded build would need Developer ID signing and
notarization to launch at all.

The `/Applications` symlink is needed because a Homebrew *formula* cannot write
outside its own prefix — only casks install into `/Applications`.

**After `brew upgrade`, re-toggle Launch at Login.** macOS records the login item
against the exact versioned path (`.../Cellar/spotifymenubar/<version>/...`), so an
upgrade leaves the old registration pointing at a directory that no longer exists.
Right-click -> Launch at Login off, then on again.

Upgrading also re-signs the bundle with a new code identity, so the one-time
"control Spotify" prompt reappears. Expected, not a bug.

## Configuration

Defaults live in the `Config` enum in
`Sources/SpotifyMenuBarCore/Config.swift`. You can override them at runtime — no
rebuild, no restart — with `defaults write`; changes apply on the next playback
change:

```bash
defaults write com.local.SpotifyMenuBar maxTrack -int 24
defaults write com.local.SpotifyMenuBar maxArtist -int 24
defaults write com.local.SpotifyMenuBar prevRestartSecs -float 2.5
defaults write com.local.SpotifyMenuBar maxWidthFraction -float 0.20
defaults write com.local.SpotifyMenuBar displayMode -string compact
defaults write com.local.SpotifyMenuBar debugLayout -bool YES
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `maxTrack` | Int | `18` | Max characters of the track name before truncation (`…`) |
| `maxArtist` | Int | `18` | Max characters of the artist name |
| `prevRestartSecs` | Double | `3.0` | Below this playback position, "back" goes to the previous track; above it, "back" restarts the current track |
| `maxWidthFraction` | Double | `0.25` | Largest share of the menu bar's status-item region this item may claim. Clamped to 0.10–1.0. This is now the *softer* of two ceilings — the measured free-space ceiling (see below) is the harder one and usually binds first — so lowering it rarely helps a crowded bar; pin a smaller layout instead. |
| `displayMode` | String | `auto` | Pins the layout: `auto`, `full`, `compact`, `icons`, `playPause`. Also available on the right-click **Display** submenu. |
| `debugLayout` | Bool | `false` | Opt-in diagnostic: logs `rung`, `text`, `requested`, `length`, `region`, `visible`, `windowFrame`, `ceiling` and `available` via `os.Logger` (not `NSLog`, whose formatted string is redacted to `<private>` in the unified log). `ceiling` is the cached value actually driving the budget; `available` is a live reading that legitimately moves with our own width, so watch `ceiling` when diagnosing stability. Read with `/usr/bin/log stream --predicate 'subsystem == "com.local.SpotifyMenuBar"' --info` (the full path avoids a shell's `log` builtin). |

Remove an override with `defaults delete com.local.SpotifyMenuBar maxTrack`.

## How it works

- **Commands** (play/pause, next, smart-previous) are sent to the Spotify desktop
  app via AppleScript / Apple Events (`NSAppleScript`).
- **Updates** are event-driven: the app observes Spotify's
  `com.spotify.client.PlaybackStateChanged` distributed notification and re-queries
  the current track via AppleScript whenever playback changes. There is no polling
  and no timer, so idle CPU is effectively zero.
- **Layout** never requests more width than `maxWidthFraction` of the status-item
  region, computed from the current screen (accounting for the notch). It re-runs
  whenever the screen configuration changes or you switch Spaces, so the item
  re-fits itself rather than staying sized for wherever it last rendered.
- The automatic layout is also capped by how much menu-bar space is actually free,
  measured from the other items' geometry. That ceiling is established while the
  item is at its smallest — the only moment the reading is honest — then reused
  across ordinary track-change relayouts, and re-established when the bar's contents
  may have changed (an app launching or quitting, a screen or Space change), rate-
  limited to roughly once every 3 seconds.

## Known limitations

- Only works while the **Spotify desktop app is running** (it controls that app; it
  is not a Web API / Connect client).
- Relies on Spotify's AppleScript dictionary and the `PlaybackStateChanged`
  notification, which are **undocumented / Spotify-internal**. They've been stable
  for years but a future Spotify client could change them.
- Built locally and **ad-hoc signed**, not notarized. Distributable via the
  Homebrew tap, which compiles on the target machine and so sidesteps Gatekeeper;
  a *prebuilt* download would need Developer ID signing and notarization.
- The automatic layout measures free space and will not displace other icons, but a
  layout pinned via **Display** deliberately overrides that, so a pinned larger
  layout can still be hidden on a crowded bar — pick a smaller one, or **Auto**.

## Project layout

```
SpotifyMenuBar/
├── Package.swift                          # SwiftPM, macOS 13+, three targets
├── Info.plist                             # bundle metadata (LSUIElement, usage strings)
├── build-app.sh                           # assembles + ad-hoc signs SpotifyMenuBar.app
├── LICENSE                                # MIT
├── README.md
├── AGENTS.md                              # instructions for AI coding agents
├── CLAUDE.md                              # → points to AGENTS.md
└── Sources/
    ├── SpotifyMenuBar/main.swift          # AppKit app (executable)
    ├── SpotifyMenuBarCore/                # pure logic library, no AppKit
    │                                       # (Config, Settings, trunc, Rung, DisplayMode, BarLayout)
    └── SpotifyMenuBarCoreTests/           # executable test runner (`swift run SpotifyMenuBarCoreTests`)
```
