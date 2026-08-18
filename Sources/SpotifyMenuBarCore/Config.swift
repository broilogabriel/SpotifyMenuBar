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
