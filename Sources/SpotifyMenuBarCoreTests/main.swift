import CoreGraphics
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

// MARK: BarLayout

// A stub measurer: 7pt per character. Keeps every check font-independent.
let measure: (String) -> CGFloat = { CGFloat($0.count) * 7 }
let notched = CGRect(x: 956, y: 1085, width: 772, height: 32)
let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

// -- region: notch present, absent (nil), and absent (empty rect)
expectClose(Double(BarLayout.region(auxiliaryTopRight: notched, screenFrame: screen).width),
            772, "notched region uses the aux area width")
expectClose(Double(BarLayout.region(auxiliaryTopRight: nil, screenFrame: screen).width),
            864, "nil aux area falls back to the right half")
expectClose(Double(BarLayout.region(auxiliaryTopRight: .zero, screenFrame: screen).width),
            864, "empty aux area falls back to the right half")
expectClose(Double(BarLayout.region(auxiliaryTopRight: nil, screenFrame: screen).minX),
            864, "the right-half fallback starts at the screen midpoint")

// -- budget: the fraction, and both clamps
expectClose(Double(BarLayout.budget(regionWidth: 772, fraction: 0.25, metrics: m)),
            193, "budget is fraction * region")
expectClose(Double(BarLayout.budget(regionWidth: 0, fraction: 0.25, metrics: m)),
            24, "a zero-width region still yields the playPause floor")
expectClose(Double(BarLayout.budget(regionWidth: 100, fraction: 4.0, metrics: m)),
            100, "budget never exceeds the region itself")

// -- ellipsisFit
expect(BarLayout.ellipsisFit("Bohemian Rhapsody", 70, measure), "Bohemian\u{2026}",
       "ellipsisFit shrinks to fit the budget")
expect(BarLayout.ellipsisFit("Queen", 70, measure), "Queen",
       "ellipsisFit leaves an already-fitting string alone")
expect(BarLayout.ellipsisFit("Bohemian Rhapsody", 6, measure), nil,
       "ellipsisFit gives up when even one char plus ellipsis overflows")

// -- resolve: the full ladder, same track at shrinking budgets
let st = Settings(maxTrack: 18, maxArtist: 18, prevRestartSecs: 3)

// "Bohemian Rhapsody" is 17 chars, so maxTrack of 18 leaves it whole.
// labelled = "Bohemian Rhapsody – Queen" = 25 chars = 175pt; + 74 chrome = 249 <= 300.
let r1 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 300,
                           settings: st, metrics: m, measure: measure)
expect(r1.rung, .full, "a roomy budget resolves to full")
expect(r1.labelText, "Bohemian Rhapsody – Queen", "full shows track and artist")
expectClose(Double(r1.totalWidth), 249, "full total width is chrome plus text")

// 193 - 74 = 119 label budget. labelled is 175 > 119, so the artist is dropped;
// trackOnly "Bohemian Rhapsody" is 17 chars = 119 <= 119, so it survives intact.
let r2 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 193,
                           settings: st, metrics: m, measure: measure)
expect(r2.rung, .compact, "a tight budget drops the artist first")
expect(r2.labelText, "Bohemian Rhapsody", "compact shows the track only")

// 74 + 40 = 114 is the smallest budget that can still hold a legible label.
// labelBudget = 46; trackOnly is 119, so this is the pixel-truncating path.
let r3 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 120,
                           settings: st, metrics: m, measure: measure)
expect(r3.rung, .compact, "just above the label floor still keeps a label")
expect(r3.labelText, "Bohem…", "the last labelled rung truncates by pixels")

let r4 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 100,
                           settings: st, metrics: m, measure: measure)
expect(r4.rung, .icons, "below the label floor drops to icons")
expect(r4.labelText, nil, "icons carries no label text")
expectClose(Double(r4.totalWidth), 68, "icons total width is its chrome")

let r5 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 30,
                           settings: st, metrics: m, measure: measure)
expect(r5.rung, .playPause, "too narrow for three icons drops to playPause")

let r6 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 0,
                           settings: st, metrics: m, measure: measure)
expect(r6.rung, .playPause, "a zero budget still renders the floor, never nothing")
expectClose(Double(r6.totalWidth), 24, "the floor is returned even when it overflows the budget")

// -- resolve respects the user's character preferences as an upper bound
let short = Settings(maxTrack: 5, maxArtist: 5, prevRestartSecs: 3)
let r7 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 300,
                           settings: short, metrics: m, measure: measure)
expect(r7.labelText, "Bohe… – Queen", "maxTrack still caps the text when pixels allow more")

// Boundary pairs: each ladder transition tested at the exact edge and one point past it,
// so an off-by-one in the guards cannot stay green.
expect(BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 114,
                         settings: st, metrics: m, measure: measure).rung, .compact,
       "the label floor exactly still yields a labelled rung")
expect(BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 113,
                         settings: st, metrics: m, measure: measure).rung, .icons,
       "one point below the label floor drops to icons")
expect(BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 68,
                         settings: st, metrics: m, measure: measure).rung, .icons,
       "the icons floor exactly still yields icons")
expect(BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 67,
                         settings: st, metrics: m, measure: measure).rung, .playPause,
       "one point below the icons floor drops to playPause")
expect(BarLayout.ellipsisFit("Bohemian Rhapsody", 14, measure), "B\u{2026}",
       "ellipsisFit at its exact give-up boundary still returns one char plus ellipsis")
expect(BarLayout.ellipsisFit("Bohemian Rhapsody", 13, measure), nil,
       "one point below that boundary gives up")

// A wide-glyph font can leave a label budget above minLabelWidth that still cannot fit
// even one character plus an ellipsis. Only a wider stub reaches that branch.
let wide: (String) -> CGFloat = { CGFloat($0.count) * 30 }
expect(BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 120,
                         settings: st, metrics: m, measure: wide).rung, .icons,
       "a label budget above the floor that still fits no text falls through to icons")

expectClose(Double(BarLayout.budget(regionWidth: 772, fraction: .nan, metrics: m)),
            24, "a NaN fraction falls back to the floor rather than poisoning the budget")

// MARK: maxWidthFraction clamping

d.set(0.0, forKey: "maxWidthFraction")
expectClose(Settings.maxWidthFraction(d), 0.10, "a zero fraction clamps up to 0.10")
d.set(9.0, forKey: "maxWidthFraction")
expectClose(Settings.maxWidthFraction(d), 1.0, "an absurd fraction clamps down to 1.0")
d.removeObject(forKey: "maxWidthFraction")
expectClose(Settings.maxWidthFraction(d), Config.maxWidthFraction, "unset uses the default")

// MARK: resolve collapses an empty artist

expect(BarLayout.resolve(track: "Advertisement", artist: "", budget: 300,
                         settings: st, metrics: m, measure: measure).labelText,
       "Advertisement", "an empty artist leaves no stranded separator")
expect(BarLayout.resolve(track: "Advertisement", artist: "", budget: 300,
                         settings: st, metrics: m, measure: measure).rung, .full,
       "an empty artist still resolves to full when it fits")

// MARK: DisplayMode

expect(DisplayMode.from("compact"), .compact, "a known raw value parses")
expect(DisplayMode.from("nonsense"), .auto, "an unknown value falls back to auto")
expect(DisplayMode.from(nil), .auto, "a missing value falls back to auto")
expect(DisplayMode.auto.pinnedRung, nil, "auto pins nothing")
expect(DisplayMode.full.pinnedRung, .full, "full pins the full rung")
expect(DisplayMode.compact.pinnedRung, .compact, "compact pins the compact rung")
expect(DisplayMode.icons.pinnedRung, .icons, "icons pins the icons rung")
expect(DisplayMode.playPause.pinnedRung, .playPause, "playPause pins the playPause rung")
expect(DisplayMode.allCases.count, 5, "auto plus one mode per rung")

d.set("icons", forKey: "displayMode")
expect(Settings.displayMode(d), .icons, "displayMode reads from defaults")
d.set("garbage", forKey: "displayMode")
expect(Settings.displayMode(d), .auto, "a garbage displayMode reads as auto")
d.removeObject(forKey: "displayMode")
expect(Settings.displayMode(d), .auto, "unset displayMode is auto")

// MARK: BarLayout.pin

// A user pin must honour the empty-artist collapse exactly as the automatic path does —
// a second label composer is how "Advertisement – " shipped once already.
expect(BarLayout.pin(.full, track: "Advertisement", artist: "", settings: st,
                     metrics: m, measure: measure).labelText,
       "Advertisement", "a pinned full rung collapses an empty artist")
expect(BarLayout.pin(.full, track: "Bohemian Rhapsody", artist: "Queen", settings: st,
                     metrics: m, measure: measure).labelText,
       "Bohemian Rhapsody – Queen", "a pinned full rung keeps a present artist")
expect(BarLayout.pin(.compact, track: "Bohemian Rhapsody", artist: "Queen", settings: st,
                     metrics: m, measure: measure).labelText,
       "Bohemian Rhapsody", "a pinned compact rung drops the artist")
expect(BarLayout.pin(.icons, track: "Bohemian Rhapsody", artist: "Queen", settings: st,
                     metrics: m, measure: measure).labelText,
       nil, "a pinned iconic rung carries no label")
expectClose(Double(BarLayout.pin(.playPause, track: "Bohemian Rhapsody", artist: "Queen",
                                 settings: st, metrics: m, measure: measure).totalWidth),
            24, "a pinned playPause rung is just its chrome")
expect(BarLayout.pin(.full, track: "Bohemian Rhapsody", artist: "Queen", settings: st,
                     metrics: m, measure: measure).rung,
       .full, "pin returns the rung it was asked for")

summarize()
