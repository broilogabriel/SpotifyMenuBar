import Foundation
import SpotifyMenuBarCore

// trunc keeps short strings whole and ellipsises long ones to exactly n characters.
expect(trunc("Queen", 18), "Queen", "trunc leaves a short string alone")
expect(trunc("Bohemian Rhapsody", 10), "Bohemian \u{2026}", "trunc ellipsises to n chars")
expect(trunc("Bohemian Rhapsody", 10).count, 10, "truncated length is exactly n")

// Settings clamps hostile UserDefaults values (AGENTS.md decision #13).
let d = UserDefaults(suiteName: "SpotifyMenuBarTests")!
d.removePersistentDomain(forName: "SpotifyMenuBarTests")
d.set(0, forKey: "maxTrack")
d.set(-5, forKey: "prevRestartSecs")
let s = Settings.current(d)
expect(s.maxTrack, 1, "maxTrack clamps up to 1")
expect(s.prevRestartSecs, 0, "prevRestartSecs clamps up to 0")
expect(s.maxArtist, Config.maxArtist, "unset key falls back to the Config default")

summarize()
