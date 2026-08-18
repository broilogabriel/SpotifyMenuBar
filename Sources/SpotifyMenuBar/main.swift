import AppKit
import ServiceManagement
import SpotifyMenuBarCore

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
    var prevButton: NSButton!
    var nextButton: NSButton!
    var loginItem: NSMenuItem!
    var menuPrevItem: NSMenuItem!
    var menuNextItem: NSMenuItem!
    var menuPrevNextSeparator: NSMenuItem!
    private var pendingRefresh: DispatchWorkItem?
    // Remembered so a momentarily screen-less window (early launch, display sleep)
    // reuses the last good geometry instead of collapsing to the floor.
    private var lastRegion = CGRect(x: 0, y: 0, width: 400, height: 24)
    // Remembered so a display change can re-run layout without a round-trip to
    // Spotify — an Apple Event on every screen-parameter notification would be
    // both slow and needless.
    private var lastTrack: (track: String, artist: String) = ("", "")

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let host = statusItem.button else { return }

        label = NSTextField(labelWithString: "♪")
        label.font = NSFont.menuBarFont(ofSize: 0)
        label.textColor = .labelColor

        prevButton = control("backward.fill", "Previous", #selector(prev))
        playButton = control("play.fill", "Play or pause", #selector(playPause))
        nextButton = control("forward.fill", "Next", #selector(next))

        // One status item, one custom view holding everything → a single
        // menu-bar slot, so the notch only ever clips this one item.
        stack = NSStackView(views: [label, prevButton, playButton, nextButton])
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
        menuPrevItem = NSMenuItem(title: "Previous", action: #selector(prev), keyEquivalent: "")
        menuPrevItem.target = self
        menuPrevItem.isHidden = true
        menu.addItem(menuPrevItem)
        menuNextItem = NSMenuItem(title: "Next", action: #selector(next), keyEquivalent: "")
        menuNextItem.target = self
        menuNextItem.isHidden = true
        menu.addItem(menuNextItem)
        menuPrevNextSeparator = .separator()
        menuPrevNextSeparator.isHidden = true
        menu.addItem(menuPrevNextSeparator)
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Spotify Menu Bar",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        for v in [host, label, prevButton, playButton, nextButton] as [NSView] { v.menu = menu }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed),
            name: .init("com.spotify.client.PlaybackStateChanged"), object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

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

    /// Dock/undock, resolution change, or a Space switch can all change the region
    /// this item has to fit into.
    @objc func screenChanged() {
        relayout(track: lastTrack.track, artist: lastTrack.artist)
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
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play or pause")
        // An empty track name makes `relayout` produce the "♪" placeholder rung and
        // clears the tooltip, so the not-running state goes through one code path.
        relayout(track: "", artist: "")
    }

    func update(track: String, artist: String, state: String) {
        let playing = state.lowercased() == "playing"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: "Play or pause")
        relayout(track: track, artist: artist)
    }

    /// The menu-bar strip this item currently lives in. Uses the status button's own
    /// screen rather than `.main` so docking to an external display recomputes it.
    func currentRegion() -> CGRect {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let screen else { return lastRegion }
        lastRegion = BarLayout.region(auxiliaryTopRight: screen.auxiliaryTopRightArea,
                                      screenFrame: screen.frame)
        return lastRegion
    }

    // Measured with a real NSTextField, not a bare NSString: the field's cell adds ~4pt
    // of inset, and if the resolver's model disagrees with the label's the clamp in
    // resize(to:) silently crops the first glyph.
    private lazy var sizer: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = label.font
        return f
    }()

    /// Text measurement is AppKit-only, so `BarLayout` takes it as a closure.
    func measureLabel(_ s: String) -> CGFloat {
        sizer.stringValue = s
        return ceil(sizer.fittingSize.width)
    }

    /// prev/next are unreachable at the playPause rung, so surface them in the
    /// right-click menu exactly when the buttons are gone.
    func prevNextMenuItems(hidden: Bool) {
        menuPrevItem?.isHidden = hidden
        menuNextItem?.isHidden = hidden
        menuPrevNextSeparator?.isHidden = hidden
    }

    /// Show exactly what this rung calls for. Hidden views leave the stack's layout,
    /// so no view is ever added or removed — the `.menu` wiring from decision #5 and
    /// the trailing anchor from #2 both survive untouched.
    func apply(_ r: BarLayout.Resolution, fullTitle: String?) {
        label.isHidden = !r.rung.showsLabel
        prevButton.isHidden = !r.rung.showsPrevNext
        nextButton.isHidden = !r.rung.showsPrevNext
        if let text = r.labelText { label.stringValue = text }

        // At iconic rungs the label is gone, so the tooltip and the VoiceOver name
        // are the only remaining way to learn what is playing. Put them on the host
        // and the buttons, not just the label.
        let host = statusItem.button
        for v in [host, label, prevButton, playButton, nextButton].compactMap({ $0 }) {
            v.toolTip = fullTitle
        }
        host?.setAccessibilityLabel(fullTitle ?? "Spotify")

        prevNextMenuItems(hidden: r.rung.showsPrevNext)
        resize(to: r.totalWidth)
    }

    /// Recompute the rung for the current track and apply it.
    func relayout(track: String, artist: String) {
        lastTrack = (track, artist)
        guard !track.isEmpty else {
            let metrics = Rung.Metrics.default
            let budget = BarLayout.budget(regionWidth: currentRegion().width,
                                          fraction: Settings.maxWidthFraction(),
                                          metrics: metrics)
            // Route the placeholder through the same tested resolver rather than a
            // second, hand-derived ladder that could drift from it.
            apply(BarLayout.resolve(track: "♪", artist: "", budget: budget,
                                    settings: Settings.current(), metrics: metrics,
                                    measure: measureLabel),
                  fullTitle: nil)
            return
        }

        let settings = Settings.current()
        let metrics = Rung.Metrics.default
        let fraction = Settings.maxWidthFraction()
        let budget = BarLayout.budget(regionWidth: currentRegion().width,
                                      fraction: fraction, metrics: metrics)
        let resolved = BarLayout.resolve(track: track, artist: artist, budget: budget,
                                         settings: settings, metrics: metrics,
                                         measure: measureLabel)
        // Ads and untagged local files report an empty artist; an unconditional
        // separator would render a stranded "Track – ".
        let fullTitle = artist.isEmpty ? track : "\(track) – \(artist)"
        apply(resolved, fullTitle: fullTitle)
    }

    /// Never request more than the budget already allowed. Still derived from the
    /// stack's fitting size (decision #6) — only now clamped, because an unbounded
    /// request is what made macOS hide this item and its neighbours.
    func resize(to allowed: CGFloat) {
        stack.layoutSubtreeIfNeeded()
        statusItem.length = min(stack.fittingSize.width + Config.padding, allowed)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no dock icon — menu-bar only
app.run()
