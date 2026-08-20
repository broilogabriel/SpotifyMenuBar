import CoreGraphics
import Foundation

/// Compile-time defaults. Runtime overrides come from `Settings` (UserDefaults).
public enum Config {
    public static let maxTrack = 18
    public static let maxArtist = 18
    public static let prevRestartSecs = 3.0   // within this many secs, "back" goes to the previous track; later it restarts
    public static let buttonWidth: CGFloat = 16
    public static let stackSpacing: CGFloat = 6
    /// Height of the menu-bar strip status items live in. `debugLayout` prints the
    /// full region rect, so this and `BarLayout.region`'s use of it must not drift.
    public static let menuBarHeight: CGFloat = 24
    /// Slack added to the stack's fitting size when setting `statusItem.length`.
    public static let padding: CGFloat = 8
    /// Below this a label is illegible, so the resolver drops the label entirely
    /// rather than render a lone ellipsis.
    public static let minLabelWidth: CGFloat = 40
    /// Share of the status-item region this one item may claim. 0.25 of a 772pt
    /// region leaves ~119pt of text (~17 chars at 13pt), close to `maxTrack`.
    public static let maxWidthFraction = 0.25
    /// Width at the LEFT edge of the status-item region that macOS will not pack into,
    /// and which `region.minX` therefore over-reports as free.
    ///
    /// Measured 2026-08-20 on the notched built-in display: with the bar crowded the
    /// occupied block bottomed out at x=984..994 against a region starting at 956, so the
    /// real reserve is ~26pt (max observed block span 746 of a 772pt region). It did not
    /// move with the frontmost app's menus (Finder 992, Terminal 992, Safari 984).
    ///
    /// 40 rather than 26 buys headroom for displays that reserve more than this one does.
    /// Getting this too small costs a neighbour's icon; too large costs at most one rung.
    /// See AGENTS.md decision #20.
    public static let barReserve: CGFloat = 40
}
