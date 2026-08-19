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
- **Right-click → Quit.**
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
is checked in the submenu and persists across relaunches.

Notes:
- The `.app` is a menu-bar agent (`LSUIElement`) — no Dock icon, no app menu.
- It's **ad-hoc signed**, so it runs locally without notarization. Re-running
  `build-app.sh` re-signs it, which may re-trigger the one-time "control Spotify"
  consent prompt.

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
| `maxWidthFraction` | Double | `0.25` | Largest share of the menu bar's status-item region this item may claim. Clamped to 0.10–1.0. Lower it if the item crowds your bar. |
| `displayMode` | String | `auto` | Pins the layout: `auto`, `full`, `compact`, `icons`, `playPause`. Also available on the right-click **Display** submenu. |
| `debugLayout` | Bool | `false` | Opt-in diagnostic: logs the resolved budget, rung, region and window frame via `NSLog`. |

Remove an override with `defaults delete com.local.SpotifyMenuBar maxTrack`.

## How it works

- **Commands** (play/pause, next, smart-previous) are sent to the Spotify desktop
  app via AppleScript / Apple Events (`NSAppleScript`).
- **Updates** are event-driven: the app observes Spotify's
  `com.spotify.client.PlaybackStateChanged` distributed notification and re-queries
  the current track via AppleScript whenever playback changes. There is no polling
  and no timer, so idle CPU is effectively zero.

## Known limitations

- Only works while the **Spotify desktop app is running** (it controls that app; it
  is not a Web API / Connect client).
- Relies on Spotify's AppleScript dictionary and the `PlaybackStateChanged`
  notification, which are **undocumented / Spotify-internal**. They've been stable
  for years but a future Spotify client could change them.
- Built locally and **ad-hoc signed**, not notarized — fine for personal use, but
  not distributable to other Macs without proper signing/notarization.

## Project layout

```
SpotifyMenuBar/
├── Package.swift                          # SwiftPM, macOS 13+, three targets
├── Info.plist                             # bundle metadata (LSUIElement, usage strings)
├── build-app.sh                           # assembles + ad-hoc signs SpotifyMenuBar.app
├── README.md
├── AGENTS.md                              # instructions for AI coding agents
├── CLAUDE.md                              # → points to AGENTS.md
└── Sources/
    ├── SpotifyMenuBar/main.swift          # AppKit app (executable)
    ├── SpotifyMenuBarCore/                # pure logic library, no AppKit
    │                                       # (Config, Settings, trunc, Rung, DisplayMode, BarLayout)
    └── SpotifyMenuBarCoreTests/           # executable test runner (`swift run SpotifyMenuBarCoreTests`)
```
