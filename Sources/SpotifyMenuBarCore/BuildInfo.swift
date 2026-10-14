/// The one-line identity of the running build, shown in the right-click menu.
///
/// The fields are stamped into the bundle's Info.plist by `build-app.sh`. Three builds
/// of the same 1.2.0 once behaved differently (one at ~90% CPU) with nothing on screen
/// to tell them apart; this line is what makes that a single right-click. AGENTS.md #22.
public enum BuildInfo {
    /// All stamps are optional: a bundle not made by `build-app.sh` (or `swift run`, with
    /// no bundle at all) must still render, and must say it is unstamped rather than
    /// look like a release.
    public static func describe(version: String?, commit: String?, sdk: String?,
                                channel: String?) -> String {
        let v = version ?? "unknown version"
        guard let sdk, !sdk.isEmpty else { return "\(v) · unstamped build" }
        var line = v
        if let commit, !commit.isEmpty { line += " (\(commit))" }
        line += " · SDK \(sdk)"
        if let channel, channel != "release" { line += " · \(channel)" }
        return line
    }
}
