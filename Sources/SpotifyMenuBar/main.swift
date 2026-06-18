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

@discardableResult
func spotify(_ body: String) -> String? {
    var err: NSDictionary?
    let out = NSAppleScript(source: "tell application \"Spotify\"\n\(body)\nend tell")?
        .executeAndReturnError(&err)
    if let err { NSLog("AppleScript error: \(err)"); return nil }
    return out?.stringValue
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var stack: NSStackView!
    var label: NSTextField!
    var playButton: NSButton!
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let host = statusItem.button else { return }

        label = NSTextField(labelWithString: "♪")
        label.font = NSFont.menuBarFont(ofSize: 0)
        label.textColor = .labelColor

        let prev = control("backward.fill",   #selector(prev))
        playButton = control("play.fill",      #selector(playPause))
        let next = control("forward.fill",     #selector(next))

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

    func control(_ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.contentTintColor = .labelColor
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: Config.buttonWidth).isActive = true
        return b
    }

    // Smart previous: near the start → go to the previous track; otherwise restart
    // the current one (so a second press from the restarted track also goes back).
    @objc func prev() {
        let threshold = Settings.current().prevRestartSecs
        spotify("if player position > \(threshold) then\n" +
                "set player position to 0\n" +
                "else\n" +
                "previous track\n" +
                "end if")
        refresh()
    }
    @objc func next()      { spotify("next track"); refresh() }
    @objc func playPause() { spotify("playpause");  refresh() }

    @objc func changed() { refresh() }

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
        guard let r = spotify(
            "if it is running then return (name of current track) & \"\\n\" & " +
            "(artist of current track) & \"\\n\" & (player state as string)")
        else { return }
        let p = r.components(separatedBy: "\n")
        if p.count == 3 { update(track: p[0], artist: p[1], state: p[2]) }
    }

    func update(track: String, artist: String, state: String) {
        let s = Settings.current()
        let title = "\(trunc(track, s.maxTrack)) – \(trunc(artist, s.maxArtist))"
        let playing = state.lowercased() == "playing"
        DispatchQueue.main.async {
            self.label.stringValue = track.isEmpty ? "♪" : title
            self.playButton.image = NSImage(
                systemSymbolName: playing ? "pause.fill" : "play.fill",
                accessibilityDescription: nil)
            self.stack.layoutSubtreeIfNeeded()
            self.statusItem.length = self.stack.fittingSize.width + 8
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no dock icon — menu-bar only
app.run()
