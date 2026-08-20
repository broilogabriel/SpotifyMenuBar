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
    ///
    /// Currently unused in production: `resolve` walks `allCases` top-down rather than
    /// stepping via `next`. This is the seam for the clip-detection demotion loop
    /// described in AGENTS.md decision #16, which is deliberately unbuilt.
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
