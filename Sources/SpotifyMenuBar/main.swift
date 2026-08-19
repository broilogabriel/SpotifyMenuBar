import AppKit
import OSLog
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
    // The widest this item may be on the current bar, measured while it was at its
    // minimum width — the only moment nothing has been evicted yet, so the only moment
    // the reading is honest. nil means "not yet known", which forces the minimum rung.
    //
    // Can go stale HIGH: a status item added or removed by an already-running process
    // (a Control Center toggle, a VPN client, a "hide icon" setting) fires none of the
    // notifications this file observes, so a neighbour can vanish or appear without us
    // re-measuring. The obvious-looking fix — clamp against a live reading inside
    // `relayout` — is a trap: shrinking on a live number restores the neighbours we'd
    // already evicted, which lowers the next live reading, which shrinks us again, a
    // downward ratchet that ends permanently at `playPause`. Measuring only at the
    // minimum rung is the only reading discipline that doesn't ratchet in either
    // direction, so a stale-high ceiling is left to heal on the next real trigger
    // instead of being "corrected" here.
    private var barCeiling: CGFloat?
    private var measuringCeiling = false
    private var ceilingAttempts = 0
    // Consecutive full retry cycles that never found a measurement. After the second,
    // `relayout` stops treating nil as "not yet known" and falls back to fraction-only —
    // the documented degraded mode — instead of retrying forever and rendering a
    // permanent bare play button in the meantime.
    private var ceilingGiveUps = 0
    // A trigger that lands while a cycle is already running carries newer information
    // than the cycle it can't interrupt; remembered so the cycle re-enters (via the
    // coalescer) once it finishes, instead of the trigger being silently dropped.
    private var remeasureQueued = false
    // Rate-limits remeasureCeiling(): most app launches/quits own no status item, and
    // without this every one of them would still cost a visible shrink-and-regrow.
    private var lastCeilingMeasurement: Date?
    // Coalesced separately from `pendingRefresh`, which covers only PlaybackStateChanged;
    // sharing one work item would let a track change cancel a pending measurement.
    private var pendingMeasure: DispatchWorkItem?

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
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickDisplayMode), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        menu.addItem(.separator())
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
        // NSWorkspace notifications post only on NSWorkspace's own centre — registering
        // these on `.default` would silently never fire.
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(barContentsMaybeChanged), name: name, object: nil)
        }

        refresh()
        remeasureCeiling()
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
    /// this item has to fit into. The immediate relayout is free — no Apple Event,
    /// since `lastTrack` already has what it needs — so the region is corrected right
    /// away rather than waiting on the 0.3s coalescer below.
    @objc func screenChanged() {
        // A ceiling measured for a different region is meaningless. Gate on an actual
        // change so Space switches — which share this selector but never move the
        // region — cost no blink.
        let previous = lastRegion
        if currentRegion() != previous { barCeiling = nil }
        relayout(track: lastTrack.track, artist: lastTrack.artist)
        barContentsMaybeChanged()
    }

    /// The bar's contents plausibly changed, so the cached ceiling is stale.
    ///
    /// Rate-limited here rather than in `remeasureCeiling()`: this is the only noisy caller
    /// (`didLaunchApplication` fires for every app, most of which own no status item), and
    /// limiting the shared function instead would also throttle the launch cycle, the
    /// Display menu, and the queued re-entry — none of which are spam.
    ///
    /// Coalesces only bursts that land within this 0.3s window, not a whole login: login
    /// items appear over several seconds, so expect a handful of sequential cycles at
    /// login, not one.
    @objc func barContentsMaybeChanged() {
        // Never drop a trigger — it carries newer information than whatever is cached.
        // Defer it to the end of the rate-limit window instead.
        var delay = 0.3
        if let last = lastCeilingMeasurement {
            delay = max(delay, 3 - Date().timeIntervalSince(last))
        }
        pendingMeasure?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.remeasureCeiling() }
        pendingMeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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

    @objc func pickDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "displayMode")
        // Reflect the choice immediately — `remeasureCeiling()` returns early under a pin
        // and would otherwise leave the menu selection with no visible effect.
        relayout(track: lastTrack.track, artist: lastTrack.artist)
        // Then re-establish an honest ceiling. Under a pin this only clears it; on the way
        // back to Auto it measures, which is what stops a pin's stale ceiling being spent.
        remeasureCeiling()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        let current = Settings.displayMode()
        // displayMenu never gets its own delegate, so this only ever runs for the root
        // menu and `item(withTitle:)` never misses in practice. The `?? []` stays anyway —
        // cheap, and still correct if a delegate is ever attached to the submenu too.
        for item in menu.item(withTitle: "Display")?.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
        }
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

    /// The status-item windows currently on screen, plus our own rect and region.
    ///
    /// `CGWindowListCopyWindowInfo` needs **no** Screen Recording permission for bounds —
    /// only window titles (`kCGWindowName`) are gated.
    ///
    /// Our own rect comes from `NSWindow`, NOT from the list. macOS hosts NSStatusItem
    /// windows inside the **Control Center** process, so every entry reports Control
    /// Center's pid and window number; there is nothing in the list that identifies ours.
    /// The list does contain a Control-Center-owned entry at our own X/width — numerically
    /// close to `own` but not identical (observed 1pt apart) — which is harmless because
    /// `availableWidth` only reads `own.width` and the minimum `minX`, both re-queried fresh
    /// each call, so nothing accumulates.
    ///
    /// `CGWindowBounds` is global with the origin at the TOP-left of the primary display;
    /// `NSWindow.frame`/`NSScreen` coordinates put it at the BOTTOM-left. Each candidate is
    /// converted before filtering, so a window on another display whose X range happens to
    /// overlap this one's is still excluded by Y — X alone cannot tell two stacked displays
    /// apart.
    ///
    /// Returns nil while our item is not yet placed. An unplaced status window sits
    /// outside the bar region entirely (observed: `{{0, -33}, {84, 33}}`), which is the
    /// "cannot measure yet" signal `attemptCeilingMeasurement()`'s bounded retry consumes.
    ///
    /// Also returns the region so callers don't call `currentRegion()` again — it caches
    /// into `lastRegion`, so a second call would be a redundant side-effecting one.
    ///
    /// Only reads `CGWindowListCopyWindowInfo` and `window.frame`; the CG->AppKit Y
    /// conversion and the two-axis region filter are pure arithmetic and live in
    /// `BarLayout.statusWindows`, where a check can reach them.
    func statusItemFrames() -> (own: CGRect, all: [CGRect], region: CGRect)? {
        guard let window = statusItem.button?.window else { return nil }
        let region = currentRegion()
        let ownFrame = window.frame
        // Not yet positioned into the bar: refuse to measure rather than guess.
        guard ownFrame.maxX > region.minX, ownFrame.minX < region.maxX else { return nil }
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let own = CGRect(x: ownFrame.minX, y: region.minY,
                         width: ownFrame.width, height: region.height)
        // CGWindowBounds is global with the origin at the TOP-left of the primary display;
        // NSScreen coordinates put it at the BOTTOM-left. BarLayout.statusWindows converts
        // before comparing, or a window on another display whose X range overlaps this
        // one's gets counted.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? region.maxY
        let bounds: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = raw.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == statusLayer,
                  let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let w = b["Width"],
                  let cgY = b["Y"], let h = b["Height"] else { return nil }
            return (x: x, y: cgY, width: w, height: h)
        }
        let all = BarLayout.statusWindows(bounds: bounds, region: region, primaryMaxY: primaryMaxY)
        guard !all.isEmpty else { return nil }
        return (own, all, region)
    }

    /// Measured free space, or nil when the item is not yet placed.
    func measuredAvailable() -> CGFloat? {
        guard let f = statusItemFrames() else { return nil }
        let windowSpace = BarLayout.availableWidth(own: f.own, all: f.all, region: f.region)
        // The ceiling is spent as `statusItem.length`, but it is measured in window widths:
        // macOS grants a window 16pt wider than the requested length (measured at every
        // rung: 24->40, 68->84, 187.5->204, 266->282). Without this conversion every
        // ceiling is over-spent by that padding and the guarantee is off by 16pt.
        let padding = max(f.own.width - statusItem.length, 0)
        return max(windowSpace - padding, 0)
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
        // The label's font can change after `sizer` is created (e.g. a screen change
        // re-resolving `menuBarFont`); a stale model font is the one path that lets
        // `resize`'s clamp bind and crop the label's first character.
        sizer.font = label.font
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
        logLayout(r, requested: r.totalWidth)
    }

    /// Diagnostic for the clip-detection probe:
    ///   defaults write com.local.SpotifyMenuBar debugLayout -bool YES
    /// Which of these fields actually moves when macOS clips a status item is not
    /// documented; this is how we find out.
    ///
    /// `os.Logger` with an explicit `privacy: .public`, NOT `NSLog`. Current macOS
    /// redacts NSLog's formatted string to `<private>` in the unified log, so the
    /// fields were unreadable by `log show`/`log stream` — which defeats the entire
    /// purpose of a diagnostic you are meant to read back.
    private static let layoutLog = Logger(subsystem: "com.local.SpotifyMenuBar", category: "layout")

    func logLayout(_ r: BarLayout.Resolution, requested: CGFloat) {
        guard UserDefaults.standard.bool(forKey: "debugLayout") else { return }
        let w = statusItem.button?.window
        let msg = "[layout]"
            + " rung=\(r.rung)"
            + " text=\(r.labelText ?? "-")"
            + String(format: " requested=%.1f length=%.1f", requested, statusItem.length)
            + " region=\(NSStringFromRect(currentRegion()))"
            + " visible=\(statusItem.isVisible ? "Y" : "N")"
            + " windowFrame=\(w.map { NSStringFromRect($0.frame) } ?? "nil")"
            // ceiling= is what the budget actually used (cached, honest); available= is
            // the live reading, which is NOT stable by construction (it rises with our
            // own width post-eviction) — watch ceiling= for "no ratchet", not available=.
            + " ceiling=\(barCeiling.map { String(format: "%.1f", $0) } ?? "nil")"
            + " available=\(measuredAvailable().map { String(format: "%.1f", $0) } ?? "nil")"
        Self.layoutLog.notice("\(msg, privacy: .public)")
    }

    /// Recompute the rung for the current track and apply it.
    func relayout(track: String, artist: String) {
        lastTrack = (track, artist)
        // A pinned rung skips the budget entirely — that is the point of the override —
        // and it has to win on the placeholder path too, which returns early below.
        let pinned = Settings.displayMode().pinnedRung
        let settings = Settings.current()
        let metrics = Rung.Metrics.default
        let regionWidth = currentRegion().width
        let fraction = Settings.maxWidthFraction()
        // Deliberately does NOT re-measure. Ordinary relayouts reuse the cached ceiling,
        // which is what keeps the shrink-and-regrow blink rare and removes any per-track
        // ratchet. Only `remeasureCeiling()` re-reads it.
        //
        // nil after repeated failures means "cannot measure here" -> fraction-only, the
        // documented degraded mode. Before that, nil means "not yet measured" -> stay
        // minimal so we cannot evict anyone while we find out.
        let available: CGFloat? = barCeiling
            ?? (ceilingGiveUps >= 2 ? nil : Rung.playPause.chromeWidth(metrics))

        guard !track.isEmpty else {
            // Route the placeholder through the same tested plan rather than a second,
            // hand-derived ladder that could drift from it.
            let placeholder = BarLayout.plan(track: "♪", artist: "", regionWidth: regionWidth,
                                             fraction: fraction, available: available,
                                             pin: pinned, settings: settings,
                                             metrics: metrics, measure: measureLabel)
            apply(placeholder, fullTitle: nil)
            return
        }

        let resolved = BarLayout.plan(track: track, artist: artist, regionWidth: regionWidth,
                                      fraction: fraction, available: available,
                                      pin: pinned, settings: settings,
                                      metrics: metrics, measure: measureLabel)
        // Ads and untagged local files report an empty artist; an unconditional
        // separator would render a stranded "Track – ".
        let fullTitle = artist.isEmpty ? track : "\(track) – \(artist)"
        apply(resolved, fullTitle: fullTitle)
    }

    /// Re-establish `barCeiling`: drop to the minimum rung, let the window server settle,
    /// measure, then grow once into the result.
    ///
    /// The shrink is not cosmetic — it is the measurement's precondition. `available` read
    /// while we are oversized reflects neighbours we already evicted (measured: 91pt at
    /// 40pt wide versus 437pt at 282pt wide), so growing on that number ratchets.
    func remeasureCeiling() {
        // A newer trigger during an in-flight cycle carries information the cycle can't
        // use yet — re-enter through the coalescer once it finishes, rather than losing it.
        guard !measuringCeiling else { remeasureQueued = true; return }
        // A pin makes `BarLayout.plan` return before it reads `available`, so the shrink
        // below would not shrink and the reading would be taken at full pinned width —
        // invalid by construction, and it would silently rot the cache for when Auto
        // returns.
        guard Settings.displayMode().pinnedRung == nil else {
            barCeiling = nil
            return
        }
        measuringCeiling = true
        ceilingAttempts = 0
        barCeiling = nil                                       // forces the minimum rung
        relayout(track: lastTrack.track, artist: lastTrack.artist)
        attemptCeilingMeasurement()
    }

    /// Bounded retry: the window server needs a turn to place and resize the item, and at
    /// launch it may not be placed at all yet. Without the cap a permanently unplaced
    /// window would reschedule forever.
    private func attemptCeilingMeasurement() {
        ceilingAttempts += 1
        // Escalating: the window server may need noticeably longer than one turn on a busy
        // launch, and a fixed 0.08 x 6 gave up after less than half a second.
        let delay = 0.08 * pow(2.0, Double(min(ceilingAttempts - 1, 4)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let measured = self.measuredAvailable() {
                self.barCeiling = measured
                self.lastCeilingMeasurement = Date()
                self.measuringCeiling = false
                self.ceilingGiveUps = 0
                self.relayout(track: self.lastTrack.track, artist: self.lastTrack.artist)
                if self.remeasureQueued {
                    self.remeasureQueued = false
                    self.remeasureCeiling()      // direct, so the rate limit can't swallow it
                }
            } else if self.ceilingAttempts < 6 {
                self.attemptCeilingMeasurement()
            } else {
                self.measuringCeiling = false
                self.remeasureQueued = false
                self.ceilingGiveUps += 1
                if self.ceilingGiveUps < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        self?.barContentsMaybeChanged()
                    }
                }
                // Past that, stop retrying and let `relayout` use the fraction alone —
                // the documented degraded mode — rather than a permanent 24pt stub.
                self.relayout(track: self.lastTrack.track, artist: self.lastTrack.artist)
            }
        }
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
