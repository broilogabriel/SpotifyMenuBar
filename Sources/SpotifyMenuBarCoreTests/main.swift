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

// MARK: Rung ladder

expect(Rung.full.next, .compact, "full steps down to compact")
expect(Rung.compact.next, .icons, "compact steps down to icons")
expect(Rung.icons.next, .playPause, "icons steps down to playPause")
expect(Rung.playPause.next, nil, "playPause is the floor")
expect(Rung.allCases.count, 4, "four rungs")

expect(Rung.full.showsLabel, true, "full shows the label")
expect(Rung.compact.showsLabel, true, "compact shows the label")
expect(Rung.icons.showsLabel, false, "icons hides the label")
expect(Rung.playPause.showsLabel, false, "playPause hides the label")

expect(Rung.icons.showsPrevNext, true, "icons keeps prev/next")
expect(Rung.playPause.showsPrevNext, false, "playPause drops prev/next")

// Chrome = buttons + inter-view gaps + padding, with the label's own width excluded.
// full/compact: 4 views (label + 3 buttons) => 3 gaps.  3*16 + 3*6 + 8 = 74
// icons:        3 views (3 buttons)         => 2 gaps.  3*16 + 2*6 + 8 = 68
// playPause:    1 view                      => 0 gaps.  1*16 + 0*6 + 8 = 24
let m = Rung.Metrics.default
expectClose(Double(Rung.full.chromeWidth(m)), 74, "full chrome is 74pt")
expectClose(Double(Rung.compact.chromeWidth(m)), 74, "compact chrome is 74pt")
expectClose(Double(Rung.icons.chromeWidth(m)), 68, "icons chrome is 68pt")
expectClose(Double(Rung.playPause.chromeWidth(m)), 24, "playPause chrome is 24pt")

summarize()
