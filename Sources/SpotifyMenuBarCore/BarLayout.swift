import CoreGraphics
import Foundation

/// Resolves "how much room do we have" into "what should the item look like".
///
/// Deliberately pure: no AppKit, no NSScreen, no clock, no views. Text measurement
/// arrives as a closure because NSAttributedString sizing is AppKit-only, and the
/// caller owns the font. That is what makes every rule here checkable.
public enum BarLayout {

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
                      y: screenFrame.maxY - Config.menuBarHeight,
                      width: screenFrame.width / 2,
                      height: Config.menuBarHeight)
    }

    /// Never ask for more than `fraction` of the region — that greed is what makes
    /// macOS hide the item and its neighbours. Floored at the smallest rung so a
    /// bogus region can't produce a zero-width request.
    public static func budget(regionWidth: CGFloat, fraction: Double,
                              metrics: Rung.Metrics) -> CGFloat {
        let floor = Rung.playPause.chromeWidth(metrics)
        let ceiling = max(regionWidth, floor)
        // A non-finite fraction (a `defaults write … -float nan`) would otherwise
        // propagate through max/min into statusItem.length as NaN.
        let f = fraction.isFinite ? CGFloat(fraction) : 0
        return min(max(regionWidth * f, floor), ceiling)
    }

    /// How much width this item may occupy without displacing a neighbour, in **window**
    /// widths (see `measuredAvailable()`, which converts to a length budget).
    ///
    /// `own` must be one of `all`. The result is **NOT invariant to our own width** — an
    /// earlier design claimed it was and was refuted by measurement: widening evicts
    /// leftward neighbours, and their vacated space reads back as a larger gap (91pt at
    /// 40pt wide versus 437pt at 282pt wide, on the same bar). Only a reading taken at the
    /// minimum rung is honest, which is why `remeasureCeiling()` shrinks first. See
    /// AGENTS.md decision #19.
    ///
    /// Derived from the occupied block's LEFT edge rather than a sum of widths, because
    /// status items can overhang the region (measured: one ended 2pt past `region.maxX`)
    /// and can sit with gaps between them. A right-edge clamp is unnecessary here —
    /// `plan` already clamps the budget to `regionWidth`.
    ///
    /// `reserve` exists because **`region.minX` is not the leftmost pixel an item may
    /// occupy** — macOS keeps a margin there. Without it this function over-reports free
    /// space by exactly that margin, which shipped as the eviction bug it was written to
    /// prevent: measured 2026-08-20, it reported a 202pt window ceiling where the true
    /// limit was 164, so the item stayed inside its own budget and still hid a neighbour's
    /// icon. Pass `Config.barReserve` unless you are deliberately reproducing that.
    public static func availableWidth(own: CGRect, all: [CGRect], region: CGRect,
                                      reserve: CGFloat) -> CGFloat {
        let leftEdge = all.map(\.minX).min() ?? own.minX
        return max(own.width + (leftEdge - region.minX) - reserve, 0)
    }

    /// Keep only the status-item rects that belong to `region`, converting from
    /// CGWindowBounds' top-left origin to AppKit's bottom-left.
    ///
    /// Both axes must intersect: X alone cannot tell two stacked displays apart, which
    /// shipped as a real defect once.
    public static func statusWindows(bounds: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)],
                                     region: CGRect, primaryMaxY: CGFloat) -> [CGRect] {
        bounds.compactMap { b in
            let rect = CGRect(x: b.x, y: primaryMaxY - (b.y + b.height), width: b.width, height: b.height)
            guard rect.maxX > region.minX, rect.minX < region.maxX,
                  rect.maxY > region.minY, rect.minY < region.maxY else { return nil }
            return rect
        }
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

    /// The single place a label string is composed. Both the automatic path and a user
    /// pin route through here, so the empty-artist collapse cannot be reimplemented
    /// incorrectly at a second site — which is exactly how a stranded "Track – " once
    /// shipped.
    static func labelText(for rung: Rung, track: String, artist: String,
                          settings: Settings) -> String {
        let trackOnly = trunc(track, settings.maxTrack)
        guard rung == .full, !artist.isEmpty else { return trackOnly }
        return "\(trackOnly) – \(trunc(artist, settings.maxArtist))"
    }

    /// Walk the ladder top-down and return the first rung that fits.
    ///
    /// `full` is chosen only when the preferred string fits *without* pixel
    /// truncation; anything tighter drops the artist before mangling the track,
    /// which is the stated priority — controls survive, text degrades.
    ///
    /// At the floor, `totalWidth` may exceed `budget`: the item always renders
    /// something, even when the budget itself is zero or smaller than playPause's
    /// own chrome.
    public static func resolve(track: String, artist: String, budget: CGFloat,
                               settings: Settings, metrics: Rung.Metrics,
                               measure: (String) -> CGFloat) -> Resolution {
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

            let preferred = labelText(for: rung, track: track, artist: artist, settings: settings)
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

    /// Re-render at a rung the user pinned explicitly, skipping the budget on purpose —
    /// the user is trading the safety margin for their stated preference, and clamping
    /// a pin to the same budget `resolve` uses would make it meaningless (`resolve`
    /// would already have picked that rung if it fit).
    ///
    /// `regionWidth` is the only ceiling, and it is 100% of the region: it exists so an
    /// absurd `maxTrack`/`maxArtist` override can't run away, not to guarantee the item
    /// stays visible. A pinned larger rung on a crowded bar can still get hidden by
    /// macOS; the remedy is the user's — pick a smaller rung, or Auto.
    public static func pin(_ rung: Rung, track: String, artist: String,
                           regionWidth: CGFloat, settings: Settings,
                           metrics: Rung.Metrics,
                           measure: (String) -> CGFloat) -> Resolution {
        let chrome = rung.chromeWidth(metrics)
        guard rung.showsLabel else { return Resolution(rung: rung, labelText: nil, totalWidth: chrome) }
        let preferred = labelText(for: rung, track: track, artist: artist, settings: settings)
        let room = max(regionWidth - chrome, 0)
        let text = measure(preferred) <= room
            ? preferred
            : (ellipsisFit(preferred, room, measure) ?? preferred)
        return Resolution(rung: rung, labelText: text, totalWidth: chrome + measure(text))
    }

    /// The whole layout decision: resolve against the budget, then let a user pin
    /// override the rung. One place, so the two callers cannot drift.
    ///
    /// `available` is measured free space (nil when unmeasurable). It is a *harder*
    /// ceiling than `fraction`: exceeding it makes macOS hide a neighbouring app's icon,
    /// which is the bug this parameter exists to prevent.
    public static func plan(track: String, artist: String, regionWidth: CGFloat,
                            fraction: Double, available: CGFloat?, pin pinned: Rung?,
                            settings: Settings, metrics: Rung.Metrics,
                            measure: (String) -> CGFloat) -> Resolution {
        if let pinned {
            // A pin deliberately overrides the budget AND the measurement: the user is
            // overruling the safety margin, and capping it here would make the Display
            // submenu a hint rather than a setting. This is the one path that can still
            // displace a neighbour.
            return pin(pinned, track: track, artist: artist, regionWidth: regionWidth,
                       settings: settings, metrics: metrics, measure: measure)
        }
        var b = budget(regionWidth: regionWidth, fraction: fraction, metrics: metrics)
        if let available {
            // Floored at the smallest rung: the item must always render something, even
            // when there is genuinely no room.
            b = max(min(b, available), Rung.playPause.chromeWidth(metrics))
        }
        return resolve(track: track, artist: artist, budget: b,
                       settings: settings, metrics: metrics, measure: measure)
    }
}
