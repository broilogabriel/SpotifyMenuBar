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
