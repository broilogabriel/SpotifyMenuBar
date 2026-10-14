import CoreGraphics

/// What a left click on the status item was aimed at.
///
/// On macOS 27 the click never reaches the prev/play/next buttons: the menu bar delivers
/// it as one action on the host button, with `locationInWindow` pinned to the window's
/// centre wherever the user clicked. `NSEvent.mouseLocation` and the window frame are
/// still real, so the target is recovered from those. See AGENTS.md decision #21.
public enum ClickTarget: Equatable, Sendable {
    case label, prev, play, next, none

    /// One visible view's horizontal extent, in screen coordinates.
    public struct Zone: Equatable, Sendable {
        public let target: ClickTarget
        public let minX: CGFloat
        public let maxX: CGFloat

        public init(target: ClickTarget, minX: CGFloat, maxX: CGFloat) {
            self.target = target
            self.minX = minX
            self.maxX = maxX
        }
    }

    /// Slack above and below the window. The built-in display's item window ends exactly
    /// at the screen's top edge, so a click on the top pixel sits on `maxY` — outside
    /// `CGRect.contains`, which is half-open.
    public static let verticalSlack: CGFloat = 2

    /// Resolve `cursor` against the visible views' `zones`.
    ///
    /// Outside the window (with `verticalSlack`) is `.none`, never a guessed action: a
    /// stale frame or a pointer that moved before the action arrived must not fire
    /// anything. Inside, zones split at the midpoints between neighbours, so gaps and
    /// half-point frames leave no dead sliver; the outermost zones run to the window
    /// edges, so padding counts too. An exact midpoint goes to the right-hand zone.
    ///
    /// `zones` must hold only views that are actually shown — the label included, so a
    /// click on the text stays `.label` instead of being swallowed by prev.
    public static func resolve(cursor: CGPoint, window: CGRect, zones: [Zone]) -> ClickTarget {
        guard cursor.x >= window.minX, cursor.x <= window.maxX,
              cursor.y >= window.minY - verticalSlack, cursor.y <= window.maxY + verticalSlack
        else { return .none }
        let sorted = zones.sorted { $0.minX < $1.minX }
        guard let last = sorted.last else { return .none }
        for (left, right) in zip(sorted, sorted.dropFirst())
        where cursor.x < (left.maxX + right.minX) / 2 {
            return left.target
        }
        return last.target
    }
}
