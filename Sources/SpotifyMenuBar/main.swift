import AppKit
import ServiceManagement

// MARK: - Config

/// Compile-time defaults. Runtime overrides come from `Settings` (UserDefaults).
enum Config {
    static let maxTrack = 18
    static let maxArtist = 18
    static let prevRestartSecs = 3.0   // within this many secs, "back" goes to the previous track; later it restarts
    static let buttonWidth: CGFloat = 16
    static let stackSpacing: CGFloat = 6
}

/// Runtime-overridable tunables. Read fresh on every refresh so `defaults write`
/// takes effect on the next playback change — no restart. Values are clamped so a
/// bad write can't break layout.
struct Settings {
    let maxTrack: Int
    let maxArtist: Int
    let prevRestartSecs: Double

    static func current() -> Settings {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            max(1, d.object(forKey: key) as? Int ?? fallback)
        }
        return Settings(
            maxTrack: int("maxTrack", Config.maxTrack),
            maxArtist: int("maxArtist", Config.maxArtist),
            prevRestartSecs: max(0, d.object(forKey: "prevRestartSecs") as? Double ?? Config.prevRestartSecs))
    }
}

func trunc(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}

// MARK: - Spotify control

final class SpotifyClient {
    private let queue = DispatchQueue(label: "com.local.SpotifyMenuBar.applescript")

    /// Is the Spotify desktop app running? Checked via NSWorkspace so we never
    /// trigger the `tell application "Spotify"` auto-launch just to read state.
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    /// Runs AppleScript on a dedicated serial thread (NSAppleScript is not
    /// thread-safe) and delivers the result back on the main thread.
    func run(_ body: String, then completion: ((String?) -> Void)? = nil) {
        queue.async {
            let result = SpotifyClient.execute(body)
            if let completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private static func execute(_ body: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: "tell application \"Spotify\"\n\(body)\nend tell")?
            .executeAndReturnError(&err)
        if let err { NSLog("AppleScript error: \(err)"); return nil }
        return out?.stringValue
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let spotify = SpotifyClient()
    var statusItem: NSStatusItem!
    var stack: NSStackView!
    var label: NSTextField!
    var playButton: NSButton!
    var loginItem: NSMenuItem!
    private var pendingRefresh: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let host = statusItem.button else { return }

        label = NSTextField(labelWithString: "♪")
        label.font = NSFont.menuBarFont(ofSize: 0)
        label.textColor = .labelColor

        let prev = control("backward.fill", "Previous", #selector(prev))
        playButton = control("play.fill", "Play or pause", #selector(playPause))
        let next = control("forward.fill", "Next", #selector(next))

        // One status item, one custom view holding everything → a single
        // menu-bar slot, so the notch only ever clips this one item.
        stack = NSStackView(views: [label, prev, playButton, next])
        stack.orientation = .horizontal
        stack.spacing = Config.stackSpacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        // Pin to the trailing edge so the buttons stay put and only the text
        // grows/shrinks leftward when the track changes.
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        // Right/control-click → Quit. Assigning an NSView `.menu` is the reliable
        // way to get a contextual menu on a status item (gesture recognizers on the
        // status button don't fire for the secondary button). Set it on every
        // interactive subview so a right-click anywhere on the item works.
        let menu = NSMenu()
        menu.delegate = self   // menuNeedsUpdate refreshes the login-item checkmark
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Spotify Menu Bar",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        for v in [host, label, prev, playButton, next] as [NSView] { v.menu = menu }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed),
            name: .init("com.spotify.client.PlaybackStateChanged"), object: nil)

        refresh()
    }

    func control(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.contentTintColor = .labelColor
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: Config.buttonWidth).isActive = true
        return b
    }

    // Smart previous: near the start → previous track; otherwise restart current
    // (so a second press from the restarted track also goes back).
    @objc func prev() {
        guard spotify.isRunning else { return }   // no-op when Spotify is closed
        let threshold = Settings.current().prevRestartSecs
        spotify.run("if player position > \(threshold) then\n" +
                    "set player position to 0\n" +
                    "else\n" +
                    "previous track\n" +
                    "end if") { [weak self] _ in self?.refresh() }
    }
    @objc func next() {
        guard spotify.isRunning else { return }   // no-op when Spotify is closed
        spotify.run("next track") { [weak self] _ in self?.refresh() }
    }
    @objc func playPause() {
        // Always allowed — launches Spotify as the deliberate "start" gesture.
        spotify.run("playpause") { [weak self] _ in self?.refresh() }
    }

    // Coalesce PlaybackStateChanged bursts (Spotify fires several per change) into
    // a single refresh, cancelling any still-pending one.
    @objc func changed() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Launch at login (SMAppService, macOS 13+)
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { NSLog("Launch-at-login toggle failed: \(error)") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func refresh() {
        guard spotify.isRunning else { reset(); return }
        spotify.run(
            "return (name of current track) & \"\\n\" & " +
            "(artist of current track) & \"\\n\" & (player state as string)"
        ) { [weak self] r in
            guard let self else { return }
            guard let r else { self.reset(); return }   // Spotify quit mid-query
            let p = r.components(separatedBy: "\n")
            if p.count == 3 { self.update(track: p[0], artist: p[1], state: p[2]) }
        }
    }

    /// Spotify unavailable → placeholder.
    func reset() {
        label.stringValue = "♪"
        label.toolTip = nil
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play or pause")
        resize()
    }

    func update(track: String, artist: String, state: String) {
        let s = Settings.current()
        let title = "\(trunc(track, s.maxTrack)) – \(trunc(artist, s.maxArtist))"
        let playing = state.lowercased() == "playing"
        label.stringValue = track.isEmpty ? "♪" : title
        label.toolTip = track.isEmpty ? nil : "\(track) – \(artist)"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: "Play or pause")
        resize()
    }

    /// Resize the single status item to fit its content.
    func resize() {
        stack.layoutSubtreeIfNeeded()
        statusItem.length = stack.fittingSize.width + 8
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no dock icon — menu-bar only
app.run()
