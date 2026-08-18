# Menu-Bar Space Adaptation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the status item from requesting more menu-bar width than exists, so it degrades through smaller layouts instead of vanishing and evicting neighbouring icons.

**Architecture:** A pure `SpotifyMenuBarCore` library computes a width budget from screen geometry and resolves it to one of four discrete content "rungs" (`full`, `compact`, `icons`, `playPause`); the AppKit executable applies that resolution by hiding stack subviews and clamping `statusItem.length`, then optionally steps down a rung if it detects it was clipped anyway.

**Tech Stack:** Swift 5.9 (tools-version), AppKit, ServiceManagement, SwiftPM, macOS 13+. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-18-menu-bar-space-adaptation-design.md`

## Global Constraints

- **No third-party dependencies. No SwiftUI.** Plain Swift + AppKit only.
- **`swift-tools-version` stays at `5.9`.** Do not bump to 6.0 — it switches the package to Swift 6 language mode and its strict concurrency checking ripples into the AppKit code.
- **`SpotifyMenuBarCore` must never `import AppKit`.** `import Foundation` only. This is what keeps it testable; an AppKit import in Core is a task failure.
- **No `XCTest`, no `swift-testing`, no `.testTarget`, no `swift test`.** Verified 2026-08-18: this machine has no Xcode and the Command Line Tools toolchain ships neither module. Tests are the `SpotifyMenuBarCoreTests` **executable** target, run with `swift run SpotifyMenuBarCoreTests`.
- **Never run `swift run SpotifyMenuBar`** (no target suffix, or the app target) from a non-interactive context — it launches a blocking GUI app. `swift run SpotifyMenuBarCoreTests` **is** safe: it exits on its own.
- **Do not regress `AGENTS.md` "Hard-won design decisions" #1–#13.** Most relevant here: #1 exactly one `NSStatusItem`; #2 content pinned to the status button's **trailing** anchor; #5 right-click menu via `NSView.menu` on every subview; #6 `statusItem.length` recomputed from the stack's `fittingSize`; #12 icon buttons keep `accessibilityDescription`; #13 `Settings` clamps `UserDefaults` values.
- **No AI attribution anywhere** — no `Co-Authored-By`, no "Generated with Claude", in commits, PRs, comments, or docs.
- **Conventional Commits 1.0.0** for every commit: `<type>[scope]: <description>`, imperative, lower-case, no trailing period.
- **Comment the *why*, not the *what*.** Match the existing terse style.
- **Branch:** `feat/menu-bar-improvements` (already checked out; spec already committed there).
- Fixed metrics, from the existing `Config`: `buttonWidth: CGFloat = 16`, `stackSpacing: CGFloat = 6`, status-item padding `8`, new `minLabelWidth: CGFloat = 40`.
- Derived chrome widths, used throughout: `full`/`compact` = **74pt**, `icons` = **68pt**, `playPause` = **24pt**.
- Build command and expected output: `swift build` → `Build complete!`. A failure prints `error:` lines.
- **Core files that touch `CGRect`/`CGFloat` must `import CoreGraphics`.** `import Foundation` alone does not expose `CGRect.width`/`.midX` or `CGRect(x:y:width:height:)` — verified 2026-08-18, it fails with `value of type 'CGRect' has no member 'width'`.
- Every expected label string, width and check count in this plan was produced by running a prototype of `Rung` + `BarLayout` against the 7pt-per-character stub measurer, not derived by hand. If a check fails, suspect the implementation before the expectation.

---

### Task 1: Split the package into Core + App + test runner

Restructure the single-target package so the pure logic can be exercised by a runner. Moves `Config`, `Settings` and `trunc` into the library unchanged apart from access control. **No behavior change.**

**Files:**
- Modify: `Package.swift` (whole file)
- Create: `Sources/SpotifyMenuBarCore/Config.swift`
- Create: `Sources/SpotifyMenuBarCore/Settings.swift`
- Create: `Sources/SpotifyMenuBarCore/Text.swift`
- Create: `Sources/SpotifyMenuBarCoreTests/Harness.swift`
- Create: `Sources/SpotifyMenuBarCoreTests/main.swift`
- Modify: `Sources/SpotifyMenuBar/main.swift` (delete the moved `Config`/`Settings`/`trunc` blocks at lines 4–37; add `import SpotifyMenuBarCore`)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `public enum Config` with `static let maxTrack: Int`, `maxArtist: Int`, `prevRestartSecs: Double`, `buttonWidth: CGFloat`, `stackSpacing: CGFloat`, `padding: CGFloat`, `minLabelWidth: CGFloat`, `maxWidthFraction: Double`
  - `public struct Settings` with `let maxTrack: Int`, `maxArtist: Int`, `prevRestartSecs: Double`, and `public static func current(_ defaults: UserDefaults = .standard) -> Settings`
  - `public func trunc(_ s: String, _ n: Int) -> String`
  - Test harness: `func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String)`, `func expectClose(_ actual: Double, _ expected: Double, _ what: String, tolerance: Double = 0.5)`, `func summarize() -> Never`

- [ ] **Step 1: Write the failing test**

Create `Sources/SpotifyMenuBarCoreTests/Harness.swift`:

```swift
// Minimal assertion harness. This toolchain (Command Line Tools, no Xcode) ships
// neither XCTest nor swift-testing, so tests are a plain executable that exits
// non-zero on failure. See AGENTS.md -> "Verification".
import Foundation

private var failures = 0
private var checks = 0

/// Both sides share one generic type, so comparing mismatched types is a compile
/// error rather than a silently-passing string comparison.
func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String,
                          file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        FileHandle.standardError.write(
            "FAIL \(what)\n  expected: \(expected)\n  actual:   \(actual)\n  at \(file):\(line)\n"
                .data(using: .utf8)!)
    }
}

func expectClose(_ actual: Double, _ expected: Double, _ what: String,
                 tolerance: Double = 0.5, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        FileHandle.standardError.write(
            "FAIL \(what)\n  expected: \(expected) +/- \(tolerance)\n  actual:   \(actual)\n  at \(file):\(line)\n"
                .data(using: .utf8)!)
    }
}

func summarize() -> Never {
    print("\(checks - failures)/\(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
}
```

Create `Sources/SpotifyMenuBarCoreTests/main.swift`:

```swift
// Foundation is needed for UserDefaults — Swift does not re-export a
// dependency module's own imports, so importing Core is not enough.
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: FAIL — the target does not exist yet. `error: no target named 'SpotifyMenuBarCoreTests'`

- [ ] **Step 3: Rewrite `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifyMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic, no AppKit — this is the part the test runner can exercise.
        .target(name: "SpotifyMenuBarCore", path: "Sources/SpotifyMenuBarCore"),
        .executableTarget(
            name: "SpotifyMenuBar",
            dependencies: ["SpotifyMenuBarCore"],
            path: "Sources/SpotifyMenuBar"),
        // An executable, not a .testTarget: the Command Line Tools toolchain ships
        // neither XCTest nor swift-testing, so `swift test` cannot work here.
        .executableTarget(
            name: "SpotifyMenuBarCoreTests",
            dependencies: ["SpotifyMenuBarCore"],
            path: "Sources/SpotifyMenuBarCoreTests"),
    ]
)
```

- [ ] **Step 4: Create `Sources/SpotifyMenuBarCore/Config.swift`**

Copied from `main.swift` lines 4–13, made `public`, plus the four new constants this feature needs.

```swift
import CoreGraphics
import Foundation

/// Compile-time defaults. Runtime overrides come from `Settings` (UserDefaults).
public enum Config {
    public static let maxTrack = 18
    public static let maxArtist = 18
    public static let prevRestartSecs = 3.0   // within this many secs, "back" goes to the previous track; later it restarts
    public static let buttonWidth: CGFloat = 16
    public static let stackSpacing: CGFloat = 6
    /// Slack added to the stack's fitting size when setting `statusItem.length`.
    public static let padding: CGFloat = 8
    /// Below this a label is illegible, so the resolver drops the label entirely
    /// rather than render a lone ellipsis.
    public static let minLabelWidth: CGFloat = 40
    /// Share of the status-item region this one item may claim. 0.25 of a 772pt
    /// region leaves ~119pt of text (~17 chars at 13pt), close to `maxTrack`.
    public static let maxWidthFraction = 0.25
}
```

- [ ] **Step 5: Create `Sources/SpotifyMenuBarCore/Settings.swift`**

Copied from `main.swift` lines 15–33. Two changes: `public`, and `current` takes an injectable `UserDefaults` so the runner can use a throwaway suite.

```swift
import Foundation

/// Runtime-overridable tunables. Read fresh on every refresh so `defaults write`
/// takes effect on the next playback change — no restart. Values are clamped so a
/// bad write can't break layout.
public struct Settings {
    public let maxTrack: Int
    public let maxArtist: Int
    public let prevRestartSecs: Double

    public init(maxTrack: Int, maxArtist: Int, prevRestartSecs: Double) {
        self.maxTrack = maxTrack
        self.maxArtist = maxArtist
        self.prevRestartSecs = prevRestartSecs
    }

    // `defaults` is injectable so tests can use a throwaway suite instead of the
    // real user domain.
    public static func current(_ defaults: UserDefaults = .standard) -> Settings {
        func int(_ key: String, _ fallback: Int) -> Int {
            max(1, defaults.object(forKey: key) as? Int ?? fallback)
        }
        return Settings(
            maxTrack: int("maxTrack", Config.maxTrack),
            maxArtist: int("maxArtist", Config.maxArtist),
            prevRestartSecs: max(0, defaults.object(forKey: "prevRestartSecs") as? Double ?? Config.prevRestartSecs))
    }
}
```

- [ ] **Step 6: Create `Sources/SpotifyMenuBarCore/Text.swift`**

Copied verbatim from `main.swift` lines 35–37, made `public`.

```swift
import Foundation

public func trunc(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}
```

- [ ] **Step 7: Strip the moved code out of `Sources/SpotifyMenuBar/main.swift`**

Delete lines 4–37 — the `// MARK: - Config` block, `enum Config`, `struct Settings` and `func trunc` — and add the Core import. The file's first lines become:

```swift
import AppKit
import ServiceManagement
import SpotifyMenuBarCore

// MARK: - Spotify control
```

Everything from `final class SpotifyClient` onward is unchanged.

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `6/6 checks passed`, exit code 0. Confirm with `echo $?` → `0`.

- [ ] **Step 9: Verify the app still builds and still bundles**

Run: `swift build`
Expected: `Build complete!`

Run: `./build-app.sh`
Expected: completes and prints `Built: …/SpotifyMenuBar.app`. The library links statically, so the bundle stays self-contained and the binary name is unchanged.

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources/
git commit -m "refactor: split pure logic into SpotifyMenuBarCore with a test runner

The width-budget arithmetic this feature needs is otherwise only checkable by
squinting at a menu bar. SwiftPM cannot test an executable target, and this
toolchain has no XCTest or swift-testing, so the pure code moves to a library
exercised by a plain executable runner."
```

---

### Task 2: `Rung` — the degradation ladder

The four content shapes and their chrome widths. Pure and fully testable.

**Files:**
- Create: `Sources/SpotifyMenuBarCore/Rung.swift`
- Modify: `Sources/SpotifyMenuBarCoreTests/main.swift` (append checks before `summarize()`)

**Interfaces:**
- Consumes: `Config` (Task 1).
- Produces:
  - `public enum Rung: Int, CaseIterable, Sendable { case full = 0, compact, icons, playPause }`
  - `public var next: Rung?` — the next rung down, nil at `playPause`
  - `public var showsLabel: Bool` — true for `full` and `compact`
  - `public var showsPrevNext: Bool` — false only for `playPause`
  - `public struct Metrics` with `buttonWidth`, `spacing`, `padding`, `minLabelWidth` (all `CGFloat`) and `public static let `default``
  - `public func chromeWidth(_ metrics: Metrics) -> CGFloat`

- [ ] **Step 1: Write the failing test**

Append to `Sources/SpotifyMenuBarCoreTests/main.swift`, immediately above the `summarize()` line:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: FAIL to compile — `error: cannot find 'Rung' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/SpotifyMenuBarCore/Rung.swift`:

```swift
import CoreGraphics
import Foundation

/// The discrete content shapes the status item can take, in degradation order.
/// `playPause` is the floor — the item always renders something, never nothing.
public enum Rung: Int, CaseIterable, Sendable {
    case full = 0     // "Track – Artist" + prev/play/next
    case compact      // "Track" + prev/play/next
    case icons        // prev/play/next
    case playPause    // play/pause only; prev/next move into the right-click menu

    /// The next rung down, or nil at the floor.
    public var next: Rung? { Rung(rawValue: rawValue + 1) }

    public var showsLabel: Bool { self == .full || self == .compact }
    public var showsPrevNext: Bool { self != .playPause }

    /// Fixed layout metrics. Injected rather than read from `Config` directly so
    /// checks can pin exact numbers independent of the shipped defaults.
    public struct Metrics: Sendable {
        public let buttonWidth: CGFloat
        public let spacing: CGFloat
        public let padding: CGFloat
        public let minLabelWidth: CGFloat

        public init(buttonWidth: CGFloat, spacing: CGFloat,
                    padding: CGFloat, minLabelWidth: CGFloat) {
            self.buttonWidth = buttonWidth
            self.spacing = spacing
            self.padding = padding
            self.minLabelWidth = minLabelWidth
        }

        public static let `default` = Metrics(
            buttonWidth: Config.buttonWidth,
            spacing: Config.stackSpacing,
            padding: Config.padding,
            minLabelWidth: Config.minLabelWidth)
    }

    /// Everything except the label's own width: buttons, the gaps between stacked
    /// views, and the status-item padding. NSStackView puts a gap *between* views,
    /// so n views yield n-1 gaps.
    public func chromeWidth(_ m: Metrics) -> CGFloat {
        let buttons = showsPrevNext ? 3 : 1
        let views = buttons + (showsLabel ? 1 : 0)
        return CGFloat(buttons) * m.buttonWidth
            + CGFloat(max(0, views - 1)) * m.spacing
            + m.padding
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `21/21 checks passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyMenuBarCore/Rung.swift Sources/SpotifyMenuBarCoreTests/main.swift
git commit -m "feat(layout): add the Rung degradation ladder"
```

---

### Task 3: `BarLayout` — region, budget, and rung resolution

The heart of the feature: a pure resolver from screen geometry plus track metadata to a concrete layout. No AppKit, no clock, no views.

**Files:**
- Create: `Sources/SpotifyMenuBarCore/BarLayout.swift`
- Modify: `Sources/SpotifyMenuBarCoreTests/main.swift` (append checks before `summarize()`)

**Interfaces:**
- Consumes: `Rung`, `Rung.Metrics`, `Settings`, `Config`, `trunc` (Tasks 1–2).
- Produces:
  - `public struct BarLayout`
  - `public struct BarLayout.Resolution: Equatable` — `let rung: Rung`, `let labelText: String?`, `let totalWidth: CGFloat`
  - `public static func region(auxiliaryTopRight: CGRect?, screenFrame: CGRect) -> CGRect`
  - `public static func budget(regionWidth: CGFloat, fraction: Double, metrics: Rung.Metrics) -> CGFloat`
  - `public static func ellipsisFit(_ s: String, _ budget: CGFloat, _ measure: (String) -> CGFloat) -> String?`
  - `public static func resolve(track: String, artist: String, budget: CGFloat, settings: Settings, metrics: Rung.Metrics, measure: (String) -> CGFloat) -> Resolution`

- [ ] **Step 1: Write the failing test**

Append to `Sources/SpotifyMenuBarCoreTests/main.swift`, immediately above `summarize()`:

```swift
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

// -- resolve respects the user's character preferences as an upper bound
let short = Settings(maxTrack: 5, maxArtist: 5, prevRestartSecs: 3)
let r7 = BarLayout.resolve(track: "Bohemian Rhapsody", artist: "Queen", budget: 300,
                           settings: short, metrics: m, measure: measure)
expect(r7.labelText, "Bohe… – Queen", "maxTrack still caps the text when pixels allow more")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: FAIL to compile — `error: cannot find 'BarLayout' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/SpotifyMenuBarCore/BarLayout.swift`:

```swift
import CoreGraphics
import Foundation

/// Resolves "how much room do we have" into "what should the item look like".
///
/// Deliberately pure: no AppKit, no NSScreen, no clock, no views. Text measurement
/// arrives as a closure because NSAttributedString sizing is AppKit-only, and the
/// caller owns the font. That is what makes every rule here checkable.
public struct BarLayout {

    public struct Resolution: Equatable {
        public let rung: Rung
        public let labelText: String?
        public let totalWidth: CGFloat

        public init(rung: Rung, labelText: String?, totalWidth: CGFloat) {
            self.rung = rung
            self.labelText = labelText
            self.totalWidth = totalWidth
        }
    }

    /// The menu-bar strip status items actually live in.
    ///
    /// `auxiliaryTopRightArea` is the region to the right of the notch. Swift imports
    /// it as an Optional even though the ObjC header declares a plain NSRect, and the
    /// header also documents it as *empty* when there is no such area — so both nil
    /// and zero-width mean "no notch" and both must be handled.
    public static func region(auxiliaryTopRight: CGRect?, screenFrame: CGRect) -> CGRect {
        if let aux = auxiliaryTopRight, aux.width > 0 { return aux }
        // No notch: status items share the right half of the bar with the app menus
        // on the left. Half is a deliberate under-estimate — being wrong here costs a
        // rung, while over-estimating costs the whole item.
        return CGRect(x: screenFrame.midX,
                      y: screenFrame.maxY - 24,
                      width: screenFrame.width / 2,
                      height: 24)
    }

    /// Never ask for more than `fraction` of the region — that greed is what makes
    /// macOS hide the item and its neighbours. Floored at the smallest rung so a
    /// bogus region can't produce a zero-width request.
    public static func budget(regionWidth: CGFloat, fraction: Double,
                              metrics: Rung.Metrics) -> CGFloat {
        let floor = Rung.playPause.chromeWidth(metrics)
        let ceiling = max(regionWidth, floor)
        return min(max(regionWidth * CGFloat(fraction), floor), ceiling)
    }

    /// Shrink `s` until it measures within `budget`, appending an ellipsis. Returns
    /// nil when even one character plus the ellipsis overflows — the caller then
    /// drops the label instead of showing a bare "…".
    public static func ellipsisFit(_ s: String, _ budget: CGFloat,
                                   _ measure: (String) -> CGFloat) -> String? {
        if measure(s) <= budget { return s }
        var n = s.count - 1
        while n >= 1 {
            // Trim trailing space before the ellipsis, or cutting "Bohemian Rhapsody"
            // at 9 chars yields "Bohemian …" with a stranded gap.
            let head = String(s.prefix(n)).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression)
            if !head.isEmpty, measure(head + "…") <= budget { return head + "…" }
            n -= 1
        }
        return nil
    }

    /// Walk the ladder top-down and return the first rung that fits.
    ///
    /// `full` is chosen only when the preferred string fits *without* pixel
    /// truncation; anything tighter drops the artist before mangling the track,
    /// which is the stated priority — controls survive, text degrades.
    public static func resolve(track: String, artist: String, budget: CGFloat,
                               settings: Settings, metrics: Rung.Metrics,
                               measure: (String) -> CGFloat) -> Resolution {
        let labelled = "\(trunc(track, settings.maxTrack)) – \(trunc(artist, settings.maxArtist))"
        let trackOnly = trunc(track, settings.maxTrack)

        for rung in Rung.allCases {
            let chrome = rung.chromeWidth(metrics)

            guard rung.showsLabel else {
                // Iconic rungs have a fixed width; take the first that fits. playPause
                // is returned unconditionally below, so the loop always terminates.
                if chrome <= budget || rung == .playPause {
                    return Resolution(rung: rung, labelText: nil, totalWidth: chrome)
                }
                continue
            }

            let labelBudget = budget - chrome
            guard labelBudget >= metrics.minLabelWidth else { continue }

            let preferred = rung == .full ? labelled : trackOnly
            if measure(preferred) <= labelBudget {
                return Resolution(rung: rung, labelText: preferred,
                                  totalWidth: chrome + measure(preferred))
            }
            // Only the last labelled rung is allowed to truncate by pixels; `full`
            // falls through so the artist is dropped rather than shredded.
            if rung == .compact, let fitted = ellipsisFit(trackOnly, labelBudget, measure) {
                return Resolution(rung: rung, labelText: fitted,
                                  totalWidth: chrome + measure(fitted))
            }
        }

        // Unreachable in practice — the loop returns at playPause — but the floor is
        // a guarantee, so state it rather than rely on the loop's shape.
        return Resolution(rung: .playPause, labelText: nil,
                          totalWidth: Rung.playPause.chromeWidth(metrics))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `44/44 checks passed`, exit 0.

If a `resolve` check fails on the exact label string, re-derive it from the stub's 7pt-per-character rule before changing the implementation — the expectations encode the arithmetic deliberately.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyMenuBarCore/BarLayout.swift Sources/SpotifyMenuBarCoreTests/main.swift
git commit -m "feat(layout): resolve a width budget to a concrete rung

Pure resolver: screen region and track metadata in, rung plus fitted label
text out. Pixels are the hard constraint; maxTrack/maxArtist stay a preferred
upper bound."
```

---

### Task 4: Apply a resolution to the status item

Wire the resolver into `AppDelegate`. This is the task that fixes the bug: `statusItem.length` stops being unbounded.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` — `AppDelegate` (store `prev`/`next` as properties; add `barRegion`, `measure`, `apply`; rewrite `resize`, `reset`, `update`)

**Interfaces:**
- Consumes: `BarLayout`, `BarLayout.Resolution`, `Rung`, `Rung.Metrics`, `Settings`, `Config` (Tasks 1–3).
- Produces:
  - `var prevButton: NSButton!`, `var nextButton: NSButton!` on `AppDelegate`
  - `func currentRegion() -> CGRect`
  - `func measureLabel(_ s: String) -> CGFloat`
  - `func apply(_ r: BarLayout.Resolution, fullTitle: String?)`
  - `func relayout(track: String, artist: String)`

- [ ] **Step 1: Promote the two local buttons to properties**

In `applicationDidFinishLaunching`, `prev` and `next` are currently locals (`main.swift:88,90`). Rungs must hide them later, so they need to outlive the method. Change the declarations block to add:

```swift
    var prevButton: NSButton!
    var nextButton: NSButton!
```

and in `applicationDidFinishLaunching` replace

```swift
        let prev = control("backward.fill", "Previous", #selector(prev))
        playButton = control("play.fill", "Play or pause", #selector(playPause))
        let next = control("forward.fill", "Next", #selector(next))
```

with

```swift
        prevButton = control("backward.fill", "Previous", #selector(prev))
        playButton = control("play.fill", "Play or pause", #selector(playPause))
        nextButton = control("forward.fill", "Next", #selector(next))
```

Then update the two later uses in the same method — the stack init and the `.menu` loop:

```swift
        stack = NSStackView(views: [label, prevButton, playButton, nextButton])
```

```swift
        for v in [host, label, prevButton, playButton, nextButton] as [NSView] { v.menu = menu }
```

- [ ] **Step 2: Verify it still builds, unchanged in behavior**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Add the geometry and measurement helpers**

Add to `AppDelegate`, just above `resize()`:

```swift
    /// The menu-bar strip this item currently lives in. Uses the status button's own
    /// screen rather than `.main` so docking to an external display recomputes it.
    func currentRegion() -> CGRect {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let screen else { return lastRegion }
        lastRegion = BarLayout.region(auxiliaryTopRight: screen.auxiliaryTopRightArea,
                                      screenFrame: screen.frame)
        return lastRegion
    }

    /// Text measurement is AppKit-only, so `BarLayout` takes it as a closure.
    func measureLabel(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: label.font ?? NSFont.menuBarFont(ofSize: 0)]).width
    }
```

and add the backing property to the declarations block:

```swift
    // Remembered so a momentarily screen-less window (early launch, display sleep)
    // reuses the last good geometry instead of collapsing to the floor.
    private var lastRegion = CGRect(x: 0, y: 0, width: 400, height: 24)
```

- [ ] **Step 4: Add `apply` and `relayout`, and rewrite `resize`**

Replace the whole `resize()` method (`main.swift:220-224`) with:

```swift
    /// Show exactly what this rung calls for. Hidden views leave the stack's layout,
    /// so no view is ever added or removed — the `.menu` wiring from decision #5 and
    /// the trailing anchor from #2 both survive untouched.
    func apply(_ r: BarLayout.Resolution, fullTitle: String?) {
        label.isHidden = !r.rung.showsLabel
        prevButton.isHidden = !r.rung.showsPrevNext
        nextButton.isHidden = !r.rung.showsPrevNext
        if let text = r.labelText { label.stringValue = text }

        // At iconic rungs the label is gone, so the tooltip and the VoiceOver name
        // are the only remaining way to learn what is playing. Put them on the host
        // and the buttons, not just the label.
        let host = statusItem.button
        for v in [host, label, prevButton, playButton, nextButton].compactMap({ $0 }) {
            v.toolTip = fullTitle
        }
        host?.setAccessibilityLabel(fullTitle ?? "Spotify")

        prevNextMenuItems(hidden: r.rung.showsPrevNext)
        resize(to: r.totalWidth)
    }

    /// Recompute the rung for the current track and apply it.
    func relayout(track: String, artist: String) {
        let settings = Settings.current()
        let metrics = Rung.Metrics.default
        let fraction = Settings.maxWidthFraction()
        let budget = BarLayout.budget(regionWidth: currentRegion().width,
                                      fraction: fraction, metrics: metrics)
        let resolved = BarLayout.resolve(track: track, artist: artist, budget: budget,
                                         settings: settings, metrics: metrics,
                                         measure: measureLabel)
        let fullTitle = track.isEmpty ? nil : "\(track) – \(artist)"
        apply(resolved, fullTitle: fullTitle)
    }

    /// Never request more than the budget already allowed. Still derived from the
    /// stack's fitting size (decision #6) — only now clamped, because an unbounded
    /// request is what made macOS hide this item and its neighbours.
    func resize(to allowed: CGFloat) {
        stack.layoutSubtreeIfNeeded()
        statusItem.length = min(stack.fittingSize.width + Config.padding, allowed)
    }
```

- [ ] **Step 5: Add the `maxWidthFraction` setting accessor**

In `Sources/SpotifyMenuBarCore/Settings.swift`, add to `Settings`:

```swift
    /// Clamped hard: a `defaults write` of 0 or 9 would otherwise mean "vanish" or
    /// "be greedy again", which are the two failures this whole feature exists to
    /// prevent. Matches the clamping pattern of decision #13.
    public static func maxWidthFraction(_ defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.object(forKey: "maxWidthFraction") as? Double ?? Config.maxWidthFraction
        return min(max(raw, 0.10), 1.0)
    }
```

Append to `Sources/SpotifyMenuBarCoreTests/main.swift` above `summarize()`:

```swift
// MARK: maxWidthFraction clamping

d.set(0.0, forKey: "maxWidthFraction")
expectClose(Settings.maxWidthFraction(d), 0.10, "a zero fraction clamps up to 0.10")
d.set(9.0, forKey: "maxWidthFraction")
expectClose(Settings.maxWidthFraction(d), 1.0, "an absurd fraction clamps down to 1.0")
d.removeObject(forKey: "maxWidthFraction")
expectClose(Settings.maxWidthFraction(d), Config.maxWidthFraction, "unset uses the default")
```

- [ ] **Step 6: Add the prev/next menu fallback stub**

At the `playPause` rung the two dropped controls must remain reachable. Add to `AppDelegate`, and add the two properties to the declarations block:

```swift
    var menuPrevItem: NSMenuItem!
    var menuNextItem: NSMenuItem!
```

```swift
    /// prev/next are unreachable at the playPause rung, so surface them in the
    /// right-click menu exactly when the buttons are gone.
    func prevNextMenuItems(hidden: Bool) {
        menuPrevItem?.isHidden = hidden
        menuNextItem?.isHidden = hidden
    }
```

In `applicationDidFinishLaunching`, insert into the menu construction immediately after `let menu = NSMenu()` and `menu.delegate = self`:

```swift
        menuPrevItem = NSMenuItem(title: "Previous", action: #selector(prev), keyEquivalent: "")
        menuPrevItem.target = self
        menuPrevItem.isHidden = true
        menu.addItem(menuPrevItem)
        menuNextItem = NSMenuItem(title: "Next", action: #selector(next), keyEquivalent: "")
        menuNextItem.target = self
        menuNextItem.isHidden = true
        menu.addItem(menuNextItem)
        menu.addItem(.separator())
```

- [ ] **Step 7: Route `reset` and `update` through `relayout`**

Replace `reset()` (`main.swift:201-206`) and `update(track:artist:state:)` (`main.swift:208-218`) with:

```swift
    /// Spotify unavailable → placeholder.
    func reset() {
        label.stringValue = "♪"
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play or pause")
        // An empty track name makes `relayout` produce the "♪" placeholder rung and
        // clears the tooltip, so the not-running state goes through one code path.
        relayout(track: "", artist: "")
    }

    func update(track: String, artist: String, state: String) {
        let playing = state.lowercased() == "playing"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: "Play or pause")
        relayout(track: track, artist: artist)
    }
```

`relayout` with an empty track yields a `labelText` of `" – "` at the `full` rung, which is wrong for the placeholder. Guard it at the top of `relayout`:

```swift
        guard !track.isEmpty else {
            label.stringValue = "♪"
            let metrics = Rung.Metrics.default
            let budget = BarLayout.budget(regionWidth: currentRegion().width,
                                          fraction: Settings.maxWidthFraction(),
                                          metrics: metrics)
            // The placeholder is one glyph, so only the iconic rungs can be too wide.
            let rung: Rung = budget >= Rung.icons.chromeWidth(metrics) + metrics.minLabelWidth
                ? .compact : (budget >= Rung.icons.chromeWidth(metrics) ? .icons : .playPause)
            apply(BarLayout.Resolution(rung: rung,
                                       labelText: rung.showsLabel ? "♪" : nil,
                                       totalWidth: budget),
                  fullTitle: nil)
            return
        }
```

- [ ] **Step 8: Verify build and tests**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `47/47 checks passed`, exit 0.

- [ ] **Step 9: Human verification — this is the first point the bug is actually fixed**

Ask the human to run `./build-app.sh`, replace `/Applications/SpotifyMenuBar.app`, launch it, and confirm:
1. With Spotify playing, the item shows track and artist as before on a roomy bar.
2. `defaults write com.local.SpotifyMenuBar maxWidthFraction -float 0.08` then change track → the item collapses to icons only (0.08 clamps to 0.10 → ~77pt budget), and **no other menu-bar icon disappears**.
3. `defaults write com.local.SpotifyMenuBar maxWidthFraction -float 0.03` → clamps to 0.10 as well; confirm it does not vanish.
4. `defaults delete com.local.SpotifyMenuBar maxWidthFraction` restores normal width.
5. Hovering the item at the icons rung still shows the full "Track – Artist" tooltip.

Do not proceed until the human confirms. **Never run the app from the agent session.**

- [ ] **Step 10: Commit**

```bash
git add Sources/
git commit -m "fix(menubar): never request more width than the bar can give

resize() set statusItem.length from fittingSize with no ceiling, so on a
notched display the item could claim ~45% of the status-item region; macOS
responds by hiding items, taking neighbours with it. Clamp the request to a
budget derived from the screen region and degrade through rungs instead."
```

---

### Task 5: Re-evaluate on display and space changes

Docking or undocking a monitor changes the region, and nothing currently tells the item to recompute.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` — `applicationDidFinishLaunching`, plus a new `screenChanged` and a cached last-known track

**Interfaces:**
- Consumes: `relayout(track:artist:)` (Task 4).
- Produces: `@objc func screenChanged()`; `private var lastTrack: (track: String, artist: String)` on `AppDelegate`

- [ ] **Step 1: Cache the last known track**

`relayout` needs a track to re-run with when the trigger is a display change rather than a playback change. Add to the declarations block:

```swift
    // Remembered so a display change can re-run layout without a round-trip to
    // Spotify — an Apple Event on every screen-parameter notification would be
    // both slow and needless.
    private var lastTrack: (track: String, artist: String) = ("", "")
```

and record it at the top of `relayout(track:artist:)`, before the empty-track guard:

```swift
        lastTrack = (track, artist)
```

- [ ] **Step 2: Add the handler**

Add to `AppDelegate`:

```swift
    /// Dock/undock, resolution change, or a Space switch can all change the region
    /// this item has to fit into.
    @objc func screenChanged() {
        relayout(track: lastTrack.track, artist: lastTrack.artist)
    }
```

- [ ] **Step 3: Register the observers**

In `applicationDidFinishLaunching`, immediately after the existing `DistributedNotificationCenter` registration and before `refresh()`:

```swift
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
```

- [ ] **Step 4: Verify build and tests**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `47/47 checks passed`, exit 0.

- [ ] **Step 5: Human verification**

Ask the human to rebuild, then with Spotify playing plug in or unplug an external display and confirm the item re-sizes without a track change, and that it recovers to `full` on the roomier screen.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat(menubar): recompute layout on display and space changes"
```

---

### Task 6: `Display` submenu — manual rung override

An escape hatch for setups the automatic budget reads wrong.

**Files:**
- Create: `Sources/SpotifyMenuBarCore/DisplayMode.swift`
- Modify: `Sources/SpotifyMenuBarCore/Settings.swift` (add `displayMode` accessor)
- Modify: `Sources/SpotifyMenuBarCoreTests/main.swift` (append checks)
- Modify: `Sources/SpotifyMenuBar/main.swift` — menu construction, `menuNeedsUpdate`, `relayout`, new `pickDisplayMode`

**Interfaces:**
- Consumes: `Rung`, `Settings`, `relayout` (Tasks 1–5).
- Produces:
  - `public enum DisplayMode: String, CaseIterable` — `auto`, `full`, `compact`, `icons`, `playPause`
  - `public var pinnedRung: Rung?`, `public var title: String`
  - `public static func from(_ raw: String?) -> DisplayMode`
  - `public static func displayMode(_ defaults: UserDefaults = .standard) -> DisplayMode` on `Settings`
  - `@objc func pickDisplayMode(_ sender: NSMenuItem)` on `AppDelegate`

- [ ] **Step 1: Write the failing test**

Append to `Sources/SpotifyMenuBarCoreTests/main.swift` above `summarize()`:

```swift
// MARK: DisplayMode

expect(DisplayMode.from("compact"), .compact, "a known raw value parses")
expect(DisplayMode.from("nonsense"), .auto, "an unknown value falls back to auto")
expect(DisplayMode.from(nil), .auto, "a missing value falls back to auto")
expect(DisplayMode.auto.pinnedRung, nil, "auto pins nothing")
expect(DisplayMode.icons.pinnedRung, .icons, "icons pins the icons rung")
expect(DisplayMode.allCases.count, 5, "auto plus one mode per rung")

d.set("icons", forKey: "displayMode")
expect(Settings.displayMode(d), .icons, "displayMode reads from defaults")
d.set("garbage", forKey: "displayMode")
expect(Settings.displayMode(d), .auto, "a garbage displayMode reads as auto")
d.removeObject(forKey: "displayMode")
expect(Settings.displayMode(d), .auto, "unset displayMode is auto")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: FAIL to compile — `error: cannot find 'DisplayMode' in scope`

- [ ] **Step 3: Write `DisplayMode`**

Create `Sources/SpotifyMenuBarCore/DisplayMode.swift`:

```swift
import Foundation

/// User override for the automatic rung choice. `auto` is the default and the only
/// value that consults the budget at all.
public enum DisplayMode: String, CaseIterable, Sendable {
    case auto, full, compact, icons, playPause

    /// The rung to force, or nil to let the budget decide.
    public var pinnedRung: Rung? {
        switch self {
        case .auto:      return nil
        case .full:      return .full
        case .compact:   return .compact
        case .icons:     return .icons
        case .playPause: return .playPause
        }
    }

    public var title: String {
        switch self {
        case .auto:      return "Auto"
        case .full:      return "Track and Artist"
        case .compact:   return "Track Only"
        case .icons:     return "Controls Only"
        case .playPause: return "Play/Pause Only"
        }
    }

    /// Anything unrecognised reads as `auto`, so a bad `defaults write` degrades to
    /// the sensible default rather than breaking layout (decision #13's principle).
    public static func from(_ raw: String?) -> DisplayMode {
        guard let raw, let mode = DisplayMode(rawValue: raw) else { return .auto }
        return mode
    }
}
```

- [ ] **Step 4: Add the `Settings` accessor**

Append to `Settings` in `Sources/SpotifyMenuBarCore/Settings.swift`:

```swift
    public static func displayMode(_ defaults: UserDefaults = .standard) -> DisplayMode {
        DisplayMode.from(defaults.string(forKey: "displayMode"))
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `56/56 checks passed`, exit 0.

- [ ] **Step 6: Honour the pin in `relayout`**

In `relayout(track:artist:)`, after computing `resolved` and before building `fullTitle`, add:

```swift
        // A pinned rung skips the budget entirely — that is the point of the override.
        var resolved = resolved
        if let pinned = Settings.displayMode().pinnedRung, pinned != resolved.rung {
            let chrome = pinned.chromeWidth(metrics)
            let text = pinned.showsLabel
                ? BarLayout.ellipsisFit(trunc(track, settings.maxTrack), .greatestFiniteMagnitude, measureLabel)
                : nil
            resolved = BarLayout.Resolution(
                rung: pinned,
                labelText: text,
                totalWidth: chrome + (text.map(measureLabel) ?? 0))
        }
```

Change `let resolved = BarLayout.resolve(...)` to `let baseResolved = BarLayout.resolve(...)` and `var resolved = baseResolved` accordingly so the shadowing above compiles.

For the pinned `.full` rung the label should include the artist; use this instead of the `text` line above:

```swift
            let preferred = pinned == .full
                ? "\(trunc(track, settings.maxTrack)) – \(trunc(artist, settings.maxArtist))"
                : trunc(track, settings.maxTrack)
            let text = pinned.showsLabel ? preferred : nil
```

- [ ] **Step 7: Build the submenu**

In `applicationDidFinishLaunching`, immediately before the `loginItem` construction:

```swift
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickDisplayMode), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        menu.addItem(.separator())
```

Add the action and the checkmark refresh to `AppDelegate`:

```swift
    @objc func pickDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "displayMode")
        relayout(track: lastTrack.track, artist: lastTrack.artist)
    }
```

Extend the existing `menuNeedsUpdate(_:)` — the menu is built once, so state must be set here, not at creation (decision #8):

```swift
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        let current = Settings.displayMode()
        for item in menu.item(withTitle: "Display")?.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
        }
    }
```

`menuNeedsUpdate` fires for the submenu too, where `item(withTitle: "Display")` is nil; the `?? []` makes that a no-op rather than a crash.

- [ ] **Step 8: Verify build and tests**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `56/56 checks passed`, exit 0.

- [ ] **Step 9: Human verification**

Ask the human to rebuild and confirm: the `Display` submenu appears on right-click; picking each of the five entries changes the item immediately; the checkmark tracks the choice across menu re-opens; `Auto` restores budget-driven behavior; the choice survives a quit and relaunch.

- [ ] **Step 10: Commit**

```bash
git add Sources/
git commit -m "feat(menubar): add a Display submenu to pin the layout rung"
```

---

### Task 7: Clip detection — probe first, then implement

The one part of the design resting on an unverified assumption. **Everything above already works without it**; this only adds correction for a bar crowded by *other* apps' items, which no API exposes.

**Files:**
- Modify: `Sources/SpotifyMenuBar/main.swift` — add `clipVerdict`, `applyWithFeedback`, a `debugLayout` log
- Modify: `Sources/SpotifyMenuBarCore/BarLayout.swift` (only if the probe shows the region's `minX` is needed in pure form)

**Interfaces:**
- Consumes: `apply`, `relayout`, `currentRegion` (Tasks 4–5).
- Produces: `enum Clip { case clipped, notClipped, unknown }`; `func clipVerdict(requested: CGFloat) -> Clip`; `func applyWithFeedback(_ r: BarLayout.Resolution, fullTitle: String?)`

- [ ] **Step 1: Add the diagnostic log**

Add to `AppDelegate`:

```swift
    /// Diagnostic for the clip-detection probe:
    ///   defaults write com.local.SpotifyMenuBar debugLayout -bool YES
    /// Which of these fields actually moves when macOS clips a status item is not
    /// documented; this is how we find out.
    func logLayout(_ r: BarLayout.Resolution, requested: CGFloat) {
        guard UserDefaults.standard.bool(forKey: "debugLayout") else { return }
        let w = statusItem.button?.window
        NSLog("[layout] rung=%@ text=%@ requested=%.1f length=%.1f region=%@ visible=%@ windowFrame=%@",
              String(describing: r.rung), r.labelText ?? "-", requested, statusItem.length,
              NSStringFromRect(currentRegion()), statusItem.isVisible ? "Y" : "N",
              w.map { NSStringFromRect($0.frame) } ?? "nil")
    }
```

Call it as the last line of `apply(_:fullTitle:)`:

```swift
        logLayout(r, requested: r.totalWidth)
```

- [ ] **Step 2: Build, then hand the probe to the human**

Run: `swift build`
Expected: `Build complete!`

Then ask the human to:
1. `./build-app.sh`, replace `/Applications/SpotifyMenuBar.app`, relaunch.
2. `defaults write com.local.SpotifyMenuBar debugLayout -bool YES`
3. Crowd the menu bar until the Spotify item is clipped or hidden — open apps with status items, and/or `defaults write com.local.SpotifyMenuBar maxWidthFraction -float 1.0` to make this item greedy on purpose.
4. Collect the lines with `log stream --predicate 'eventMessage CONTAINS "[layout]"' --info` (or Console.app), in both the healthy and the clipped state.
5. Report which field differs between the two: `visible=N`, `windowFrame` width smaller than `requested`, or `windowFrame` origin left of `region`.

**Stop here and wait for the human's data.** The next step's predicate is written from it.

- [ ] **Step 3: Implement `clipVerdict` from the probe result**

Add to `AppDelegate`. Enable only the predicates the probe actually confirmed — leave the others commented with a note, rather than shipping a guess:

```swift
    enum Clip { case clipped, notClipped, unknown }

    /// Three-state on purpose: `.unknown` means "no usable signal", and the caller
    /// then trusts the computed budget alone. The feature must work either way.
    func clipVerdict(requested: CGFloat) -> Clip {
        guard let window = statusItem.button?.window, window.screen != nil else { return .unknown }
        if !statusItem.isVisible { return .clipped }
        if window.frame.width + 0.5 < requested { return .clipped }
        if window.frame.minX < currentRegion().minX - 0.5 { return .clipped }
        return .notClipped
    }
```

If the probe showed **none** of these move, replace the body with `return .unknown` and a comment recording what was tested and observed. That is a legitimate outcome, not a failure — say so in the commit message.

- [ ] **Step 4: Add the bounded feedback loop**

Add to `AppDelegate`:

```swift
    /// Apply, then check whether macOS honoured it; if not, step down and retry.
    /// Bounded by the ladder itself (full→compact→icons→playPause is three steps),
    /// and every relayout restarts from the budget, so the item climbs back up on
    /// its own once the bar empties. No timer, no hysteresis state.
    func applyWithFeedback(_ r: BarLayout.Resolution, fullTitle: String?) {
        apply(r, fullTitle: fullTitle)
        guard Settings.displayMode().pinnedRung == nil else { return }  // a pin means "don't second-guess me"
        // The window frame only reflects the new length after the runloop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard case .clipped = self.clipVerdict(requested: r.totalWidth),
                  let down = r.rung.next else { return }
            let chrome = down.chromeWidth(Rung.Metrics.default)
            self.applyWithFeedback(
                BarLayout.Resolution(rung: down,
                                     labelText: down.showsLabel ? r.labelText : nil,
                                     totalWidth: down.showsLabel ? r.totalWidth : chrome),
                fullTitle: fullTitle)
        }
    }
```

Change the two `apply(resolved, fullTitle: fullTitle)` call sites in `relayout` to `applyWithFeedback(resolved, fullTitle: fullTitle)`.

- [ ] **Step 5: Verify build and tests**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run SpotifyMenuBarCoreTests`
Expected: PASS — `56/56 checks passed`, exit 0.

- [ ] **Step 6: Human verification**

Ask the human to rebuild and confirm, with `debugLayout` still on: crowding the bar makes the item step down a rung on its own; freeing the bar and changing track brings it back up; and it never flickers continuously in a steady state. If it oscillates, that is a real defect — report it rather than adding a timer.

- [ ] **Step 7: Commit**

```bash
git add Sources/SpotifyMenuBar/main.swift
git commit -m "feat(menubar): step down a rung when macOS clips the item anyway"
```

---

### Task 8: Documentation

**Files:**
- Modify: `AGENTS.md` — "Hard-won design decisions", "Conventions", "Build, run, verify"
- Modify: `README.md` — the `Display` submenu and the two new defaults keys
- Modify: `CLAUDE.md` — the single-file quick-reference line is now wrong

- [ ] **Step 1: Add the new design decisions to `AGENTS.md`**

Append entries 14–17 to the "Hard-won design decisions — do not regress these" list:

```markdown
14. **Never request more width than the budget allows.** `resize(to:)` clamps
    `statusItem.length` to a fraction (`maxWidthFraction`, default 0.25) of the
    status-item region. Before this, `length` came straight from `fittingSize`, and a
    long track title could claim ~45% of the region on a notched display — macOS
    responds by *hiding* items, so the item took its neighbours down with it.
15. **The rung ladder has a floor.** `full → compact → icons → playPause`; the item
    always renders something. At `playPause` the dropped prev/next controls appear in
    the right-click menu, so no function becomes unreachable.
16. **`clipVerdict` is deliberately three-state.** `.unknown` means macOS gave no
    usable signal, and the caller then trusts the computed budget alone. Do not
    collapse it to a Bool — the feature must work on machines where the signal is
    absent.
17. **Tooltip and `accessibilityLabel` carry the full title on the host button**, not
    only on the label, because at `icons` and `playPause` the label is hidden and they
    become the only way to know what is playing. Setting them on the label alone
    silently breaks decision #12 at reduced rungs.
```

- [ ] **Step 2: Correct the single-file claims**

In `AGENTS.md` → "Conventions", replace `- Keep it a single file unless it grows substantially.` with:

```markdown
- The AppKit app is one file (`Sources/SpotifyMenuBar/main.swift`). Pure logic lives in
  `Sources/SpotifyMenuBarCore/` so it can be exercised by the test runner — the split
  exists for that reason alone, so don't move AppKit code there. **`SpotifyMenuBarCore`
  must never `import AppKit`.**
```

In `AGENTS.md` → "Build, run, verify", replace the "There is no test suite" line with:

```markdown
- **`swift run SpotifyMenuBarCoreTests`** runs the checks for `SpotifyMenuBarCore`
  (exit 0 = pass). This is safe non-interactively — it exits on its own, unlike
  `swift run`, which launches the blocking GUI app.
- There is no `XCTest`/`swift-testing` and **`swift test` does not work**: this machine
  has no Xcode, and the Command Line Tools toolchain ships neither module. That is why
  the tests are a plain executable with a small `expect`/`summarize` harness.
```

In `CLAUDE.md`, replace the first quick-reference bullet with:

```markdown
- AppKit app is `Sources/SpotifyMenuBar/main.swift`; pure logic is in
  `Sources/SpotifyMenuBarCore/` (never `import AppKit` there). `swift build` to verify;
  `swift run SpotifyMenuBarCoreTests` for the unit checks (safe non-interactively).
  **Do not** run `swift run` — it launches a foreground GUI app that blocks.
```

- [ ] **Step 3: Document the settings in `README.md`**

Add to the configuration section, matching the existing table or list style:

```markdown
| Key | Type | Default | Meaning |
|---|---|---|---|
| `maxWidthFraction` | float | `0.25` | Largest share of the menu-bar's status-item region this item may claim. Clamped to 0.10–1.0. Lower it if the item crowds your bar. |
| `displayMode` | string | `auto` | Pin the layout: `auto`, `full`, `compact`, `icons`, `playPause`. Also on the right-click **Display** submenu. |
| `debugLayout` | bool | `false` | Log the resolved budget, rung and window frame to Console — for diagnosing space problems. |
```

Also document the right-click **Display** submenu alongside the existing Launch at Login entry.

- [ ] **Step 4: Verify nothing is stale**

Run: `grep -n "single file\|no test suite\|~130 lines" AGENTS.md CLAUDE.md README.md`
Expected: no hits that still claim a single-file app or an absent test suite. Fix any that remain.

Run: `swift build && swift run SpotifyMenuBarCoreTests`
Expected: `Build complete!` and `56/56 checks passed`.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md CLAUDE.md README.md
git commit -m "docs: document rung adaptation, the Core split, and the new defaults keys"
```

---

## Self-Review

**Spec coverage** — every spec section maps to a task:

| Spec section | Task |
|---|---|
| Problem / measured widths | Task 4 (the clamp is the fix) |
| Budget — pure function of screen geometry | Task 3 (`region`, `budget`), Task 4 (`currentRegion`) |
| `auxiliaryTopRightArea` is `NSRect?` | Task 3 `region`, checked for nil *and* empty |
| Rungs — discrete content shapes + chrome table | Task 2 |
| Text fitting in pixels, `minLabelWidth` | Task 3 (`ellipsisFit`, `resolve`) |
| Resolution algorithm | Task 3 |
| Clip feedback + three-state verdict | Task 7 |
| Unverified clipping signal → probe first | Task 7 Steps 1–3 |
| Re-evaluation triggers | Task 5 |
| Manual override / `Display` submenu | Task 6 |
| Structure: Rung / BarLayout / AppDelegate boundaries | Tasks 1–4 |
| Package layout + executable test runner | Task 1 |
| `build-app.sh` still bundles | Task 1 Step 9 |
| View mutation via `isHidden` | Task 4 Step 4 |
| Tooltip + `accessibilityLabel` at reduced rungs | Task 4 Step 4, `AGENTS.md` #17 in Task 8 |
| Failure-mode table | Task 3 (`region`/`budget` clamps), Task 4 (`lastRegion`, empty-track guard), Task 6 (`DisplayMode.from`), Task 4 Step 5 (`maxWidthFraction` clamp) |
| Settings keys table | Task 4 Step 5, Task 6 Steps 3–4, Task 8 Step 3 |
| Docs to update | Task 8 |

No gaps.

**Placeholder scan:** no "TBD", "TODO", "handle edge cases", or "similar to Task N". Task 7 Step 3 is conditional on probe data, but both branches are written out explicitly, including what to do when the signal is absent.

**Type consistency:** `Rung.Metrics.default` is the single metrics source from Task 2 onward. `BarLayout.Resolution(rung:labelText:totalWidth:)` keeps one initialiser signature across Tasks 3, 4, 6 and 7. `chromeWidth(_:)` takes `Rung.Metrics` everywhere. `Settings.current(_:)`, `Settings.maxWidthFraction(_:)` and `Settings.displayMode(_:)` all take an optional `UserDefaults` with the same default. `relayout(track:artist:)` is the single entry point used by `reset`, `update`, `screenChanged` and `pickDisplayMode`. `apply(_:fullTitle:)` is superseded by `applyWithFeedback(_:fullTitle:)` at both call sites in Task 7 Step 4.

**Known rough edge:** Task 6 Step 6 restructures `relayout`'s locals mid-task (`resolved` → `baseResolved` → `var resolved`). The implementer should read the whole step before editing.
