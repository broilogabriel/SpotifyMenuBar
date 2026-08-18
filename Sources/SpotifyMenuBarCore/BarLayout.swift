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
        // A non-finite fraction (a `defaults write … -float nan`) would otherwise
        // propagate through max/min into statusItem.length as NaN.
        let f = fraction.isFinite ? CGFloat(fraction) : 0
        return min(max(regionWidth * f, floor), ceiling)
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
    ///
    /// At the floor, `totalWidth` may exceed `budget`: the item always renders
    /// something, even when the budget itself is zero or smaller than playPause's
    /// own chrome.
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
