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
