// LoudiniApp.swift — the Loudini menu-bar app: grabs the hardware volume keys
// (VolumeKeyTap), shows the live level in the menu bar + a dropdown slider, and
// pops a HUD on every level change (HUDWindow). All state comes from the
// daemon's status.json; all changes go through the shared atomic control.json
// writers in helper/ControlFile.swift — the exact code the CLI uses.
//
// Build: menubar/build-app.sh (bundles the daemon into Loudini.app).

import AppKit
import ServiceManagement

@main
enum LoudiniMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication does not retain its delegate; keep it alive explicitly
        // (ARC may release a local after its last use, even mid-run()).
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let step = 6  // % per key press — matches the CLI and Stream Deck
    private static let fineStep = 1  // % per key press when Shift is held (small adjust)

    private var statusItem: NSStatusItem!
    private var slider: NSSlider!
    private var headerLevelLabel: NSTextField!
    private var muteItem: NSMenuItem!
    private var deviceItem: NSMenuItem!
    private var conflictItem: NSMenuItem!
    private var grabKeysItem: NSMenuItem!
    private var grabBrightnessItem: NSMenuItem!
    private var inputMonitoringItem: NSMenuItem!
    private var fixPermissionItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var monoIconItem: NSMenuItem!
    private var updateCheckItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var brightnessItem: NSMenuItem!

    // Per-app volume section (Phase 3). One row per status.json.apps entry, built
    // dynamically between `appsSeparator` and `resetAppsItem`.
    private var appsSeparator: NSMenuItem!
    private var emptyAppsItem: NSMenuItem!
    private var resetAppsItem: NSMenuItem!
    /// Live row views keyed by roster row key (bundle id, or a pid-scoped key for
    /// bundle-less sources). Reused across renders so a drag survives a gain echo.
    private var appRows: [String: AppRowViews] = [:]
    /// The ordered row keys currently shown — a cheap structural-change check.
    private var shownAppKeys: [String] = []

    private struct AppRowViews {
        let item: NSMenuItem
        let icon: NSImageView
        let name: NSTextField
        let slider: NSSlider
        let mute: NSButton
    }

    /// When on, the menu-bar logo renders as a template (single colour that
    /// follows the menu-bar text), so it blends in with other monochrome icons.
    private var wantsMonoIcon = UserDefaults.standard.bool(forKey: "monoIcon")

    /// Daily update check, on unless the user turned it off. bool(forKey:) reads
    /// an unset key as false, so read the raw object to keep the default ON.
    private var wantsUpdateCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
    private var brightnessSlider: NSSlider!

    /// External-monitor brightness over DDC (no daemon involved).
    private let ddc = DDCBrightness()
    private var wantsBrightnessGrab = true
    /// HID route for third-party keyboards whose brightness keys never become
    /// NX media-key events (e.g. Logitech).
    private var brightnessKeys: BrightnessKeyListener?

    private var keyTap: VolumeKeyTap?
    private var statusWatcher: StatusWatcher!
    private var hud: HUDWindow!
    private var axRetryTimer: Timer?

    private var daemon: Process?
    private var daemonRetryTimer: Timer?
    private var lastStatusRunning = false
    /// Last roster seen from status.json, so the per-app section can be
    /// re-rendered on menu-open against a freshly read control.json (CLI edits
    /// to silent apps never move status.json, so the reset affordance would
    /// otherwise go stale).
    private var lastApps: [AppEntry] = []
    private var lastPipelineOK = false
    private var lastShownGain = 100
    private var lastShownMuted = false
    private var isQuitting = false
    /// True while the menu is on screen, so an async update reply never inserts a
    /// row under the user's pointer mid-click.
    private var isMenuOpen = false
    private var wantsKeyGrab = true
    /// Last (gain, muted) seen running — HUD fires only when the level moves.
    private var lastLevel: (gain: Int, muted: Bool)?

    /// Control writes happen off the main thread (tap callback + UI must not block on IO).
    private let writeQueue = DispatchQueue(label: "gg.pim.loudini.menubar.write", qos: .userInitiated)

    /// The running build's version, straight from Info.plist. Never hardcoded —
    /// troubleshooting a stale permission grant depends on knowing which build
    /// this is. Falls back to 0.0.0 only when run unbundled (no Info.plist).
    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// The bundled logo, sized for the status bar (nil when running unbundled).
    private static let menuBarLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    /// Loudini's mark: four rounded level bars — a volume-control glyph that
    /// reads at 16px, distinct from Apple's stock speaker. (x, height) on an
    /// 18-pt box; each bar 2.4 wide, centred vertically.
    private static let barSpecs: [(CGFloat, CGFloat)] = [(2.4, 5), (6.0, 11), (9.6, 8), (13.2, 4.5)]
    private static func barPaths() -> NSBezierPath {
        let p = NSBezierPath()
        for (x, h) in barSpecs {
            p.append(NSBezierPath(roundedRect: NSRect(x: x, y: (18 - h) / 2, width: 2.4, height: h),
                                  xRadius: 1.1, yRadius: 1.1))
        }
        return p
    }

    /// Monochrome variant: a template image, so macOS paints it in the
    /// menu-bar text colour (adapts to light/dark).
    private static let levelBarsIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill(); barPaths().fill(); return true
        }
        img.isTemplate = true
        return img
    }()

    /// Muted variant: the bars with a crossed-out slash (a knockout gap keeps
    /// the slash legible over them). Monochrome template — mute reads the same
    /// in both icon modes, and never as a jarring colour emoji.
    private static let levelBarsMutedIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill(); barPaths().fill()
            drawSlash(color: .black)
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// Loudini's pink→purple→cyan brand ramp, drawn horizontally so each bar
    /// samples a slice of it.
    private static let brandGradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.235, blue: 0.675, alpha: 1),   // #FF3CAC
        NSColor(srgbRed: 0.525, green: 0.365, blue: 1.00, alpha: 1),   // #865DFF
        NSColor(srgbRed: 0.125, green: 0.851, blue: 1.00, alpha: 1),   // #20D9FF
    ])!
    private static func drawSlash(color: NSColor) {
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 3.2, y: 3.6)); slash.line(to: NSPoint(x: 14.8, y: 14.4))
        slash.lineCapStyle = .round
        NSGraphicsContext.current!.compositingOperation = .clear
        slash.lineWidth = 4.4; slash.stroke()          // knock out a gap under the slash
        NSGraphicsContext.current!.compositingOperation = .sourceOver
        color.setStroke(); slash.lineWidth = 2.0; slash.stroke()
    }

    /// Full-colour variant: the gradient bars.
    private static let levelBarsColorIcon: NSImage = {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            barPaths().addClip()
            brandGradient.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), angle: 0)
            return true
        }
    }()

    /// Muted colour variant: gradient bars crossed out (brand-purple slash), so
    /// mute stays colour instead of dropping to monochrome when the icon is.
    private static let levelBarsColorMutedIcon: NSImage = {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!
            ctx.saveGraphicsState()
            barPaths().addClip()
            brandGradient.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), angle: 0)
            ctx.restoreGraphicsState()
            drawSlash(color: NSColor(srgbRed: 0.525, green: 0.365, blue: 1.0, alpha: 1))
            return true
        }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        renderStatusItem()

        // Re-show yesterday's finding right away (the check itself is daily),
        // then check if one is due.
        showCachedUpdate()
        checkForUpdate()

        hud = HUDWindow()
        ensureDaemon()
        // Recover a missing daemon while status shows it down (covers crashes,
        // spawn races, and pgrep false positives — the daemon's own flock makes
        // a redundant spawn harmless).
        daemonRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.isQuitting, !self.lastStatusRunning else { return }
            self.ensureDaemon()
        }

        statusWatcher = StatusWatcher { [weak self] status in self?.statusChanged(status) }
        statusWatcher.start()

        setupKeyTap(promptIfNeeded: true)
        startKeyTapWatchdog()

        // Displays come and go — re-enumerate the DDC targets when they do.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.ddc.rediscover()
        }

        // Brightness keys, HID route (same gate as the NX route).
        brightnessKeys = BrightnessKeyListener { [weak self] up in
            guard let self, self.wantsBrightnessGrab, self.ddc.isAvailable,
                  !Self.builtInDisplayActive() else { return }
            // Shift → fine (1%) adjustment, matching the volume keys and the
            // NX/tap brightness route (handleVolumeKey fine:). The HID callback
            // carries no modifier, so read the live global modifier state here.
            let step = NSEvent.modifierFlags.contains(.shift) ? Self.fineStep : Self.step
            self.nudgeBrightness(up ? step : -step)
        }
        brightnessKeys?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        keyTap?.stop()
        brightnessKeys?.stop()
        statusWatcher.stop()
        axRetryTimer?.invalidate()
        daemonRetryTimer?.invalidate()
        writeQueue.sync {}  // drain pending control.json writes before we go
        if let d = daemon, d.isRunning { d.terminate() }  // daemon fails open on SIGTERM
    }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Header: logo + name left, live level right.
        let headerItem = NSMenuItem()
        headerItem.isEnabled = false
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        let logoView = NSImageView(frame: NSRect(x: 14, y: 6, width: 22, height: 22))
        if let logo = Self.menuBarLogo?.copy() as? NSImage {
            logo.size = NSSize(width: 22, height: 22)
            logoView.image = logo
        }
        let nameLabel = NSTextField(labelWithString: "Loudini")
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        // Fit the name so the version can sit right after it, instead of after
        // a fixed 130pt of empty space.
        nameLabel.sizeToFit()
        nameLabel.setFrameOrigin(NSPoint(x: 42, y: 9))
        // Which build is running, dimmed next to the name: it belongs to the
        // app's identity, not to the actions below, and the header already
        // pairs a name with a value.
        let versionLabel = NSTextField(labelWithString: "v\(Self.appVersion)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.sizeToFit()
        versionLabel.setFrameOrigin(NSPoint(x: nameLabel.frame.maxX + 6, y: 10))
        headerLevelLabel = NSTextField(labelWithString: "100%")
        headerLevelLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        headerLevelLabel.textColor = .secondaryLabelColor
        headerLevelLabel.alignment = .right
        headerLevelLabel.frame = NSRect(x: 196, y: 9, width: 70, height: 17)
        header.addSubview(logoView)
        header.addSubview(nameLabel)
        header.addSubview(versionLabel)
        header.addSubview(headerLevelLabel)
        headerItem.view = header
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // Volume row, Sound-menu style: quiet icon — slider — loud icon.
        let sliderItem = NSMenuItem()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        let quiet = NSImageView(frame: NSRect(x: 14, y: 8, width: 14, height: 14))
        quiet.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)
        quiet.contentTintColor = .secondaryLabelColor
        let loud = NSImageView(frame: NSRect(x: 250, y: 8, width: 17, height: 14))
        loud.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        loud.contentTintColor = .secondaryLabelColor
        slider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                          target: self, action: #selector(sliderMoved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 34, y: 3, width: 210, height: 24)
        row.addSubview(quiet)
        row.addSubview(slider)
        row.addSubview(loud)
        sliderItem.view = row
        menu.addItem(sliderItem)

        // Brightness row (external DDC displays); hidden when unavailable.
        brightnessItem = NSMenuItem()
        let bRow = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        let dim = NSImageView(frame: NSRect(x: 14, y: 8, width: 14, height: 14))
        dim.image = NSImage(systemSymbolName: "sun.min.fill", accessibilityDescription: nil)
        dim.contentTintColor = .secondaryLabelColor
        let brightIcon = NSImageView(frame: NSRect(x: 250, y: 7, width: 17, height: 16))
        brightIcon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        brightIcon.contentTintColor = .secondaryLabelColor
        brightnessSlider = NSSlider(value: 50, minValue: 0, maxValue: 100,
                                    target: self, action: #selector(brightnessSliderMoved(_:)))
        brightnessSlider.isContinuous = true
        brightnessSlider.frame = NSRect(x: 34, y: 3, width: 210, height: 24)
        bRow.addSubview(dim)
        bRow.addSubview(brightnessSlider)
        bRow.addSubview(brightIcon)
        brightnessItem.view = bRow
        brightnessItem.isHidden = true
        menu.addItem(brightnessItem)

        // No key equivalent: ⌘M reads as the system Minimize shortcut, and the
        // hardware mute key already covers this.
        muteItem = NSMenuItem(title: "Mute", action: #selector(muteClicked), keyEquivalent: "")
        muteItem.target = self
        muteItem.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
        menu.addItem(muteItem)

        deviceItem = NSMenuItem(title: "Daemon not running",
                                action: #selector(openAudioCaptureSettings), keyEquivalent: "")
        deviceItem.target = self
        deviceItem.isEnabled = false  // becomes clickable only in the "fix permission" state
        deviceItem.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)
        menu.addItem(deviceItem)

        // Shown only when a known media-key grabber is running (menuWillOpen).
        conflictItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        conflictItem.isEnabled = false
        conflictItem.isHidden = true
        conflictItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                     accessibilityDescription: "warning")
        menu.addItem(conflictItem)

        // Per-app volume section. Rows are inserted at runtime (renderApps)
        // between this separator and the reset item; the empty-state line shows
        // when nothing is playing, matching macOS's own Sound per-app list.
        appsSeparator = .separator()
        menu.addItem(appsSeparator)
        emptyAppsItem = NSMenuItem(title: "No apps are playing audio", action: nil, keyEquivalent: "")
        emptyAppsItem.isEnabled = false
        menu.addItem(emptyAppsItem)
        resetAppsItem = NSMenuItem(title: "Reset App Volumes",
                                   action: #selector(resetAppsClicked), keyEquivalent: "")
        resetAppsItem.target = self
        resetAppsItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        resetAppsItem.isHidden = true
        menu.addItem(resetAppsItem)

        menu.addItem(.separator())

        grabKeysItem = NSMenuItem(title: "Grab Volume Keys",
                                  action: #selector(toggleGrabKeys), keyEquivalent: "")
        grabKeysItem.target = self
        grabKeysItem.state = .on
        grabKeysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(grabKeysItem)

        grabBrightnessItem = NSMenuItem(title: "Grab Brightness Keys",
                                        action: #selector(toggleGrabBrightness), keyEquivalent: "")
        grabBrightnessItem.target = self
        grabBrightnessItem.state = .on
        grabBrightnessItem.isHidden = true
        grabBrightnessItem.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        menu.addItem(grabBrightnessItem)

        // Brightness keys on third-party keyboards need Input Monitoring to be
        // captured at the HID layer. Shown only when that's the missing piece.
        inputMonitoringItem = NSMenuItem(title: "Enable Brightness Keys (Input Monitoring)…",
                                         action: #selector(enableInputMonitoring), keyEquivalent: "")
        inputMonitoringItem.target = self
        inputMonitoringItem.isHidden = true
        inputMonitoringItem.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
        menu.addItem(inputMonitoringItem)

        // The rebuild-invalidated-grant trap: Settings shows the toggle ON while
        // macOS denies the new binary. One click wipes our TCC entry and
        // re-prompts fresh.
        fixPermissionItem = NSMenuItem(title: "Fix Volume-Key Permission…",
                                       action: #selector(fixAccessibilityClicked), keyEquivalent: "")
        fixPermissionItem.target = self
        fixPermissionItem.isHidden = true
        fixPermissionItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                                          accessibilityDescription: nil)
        menu.addItem(fixPermissionItem)

        accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…",
                                       action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        accessibilityItem.isHidden = true
        accessibilityItem.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
        menu.addItem(loginItem)

        monoIconItem = NSMenuItem(title: "Monochrome Icon",
                                  action: #selector(toggleMonoIcon), keyEquivalent: "")
        monoIconItem.target = self
        monoIconItem.state = wantsMonoIcon ? .on : .off
        monoIconItem.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        menu.addItem(monoIconItem)

        updateCheckItem = NSMenuItem(title: "Check for Updates Automatically",
                                     action: #selector(toggleUpdateCheck), keyEquivalent: "")
        updateCheckItem.target = self
        updateCheckItem.state = wantsUpdateCheck ? .on : .off
        updateCheckItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(updateCheckItem)

        // Shown only when GitHub reports a strictly newer release; clicking it
        // opens the releases page — Loudini never downloads or installs itself.
        updateItem = NSMenuItem(title: "", action: #selector(updateClicked), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Loudini", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// The first running app known to fight with Loudini, or nil. Which apps those are —
    /// and what to tell the user about each — lives in helper/Conflicts.swift, the same
    /// list `loudini doctor` checks, so the two never give conflicting advice.
    private func runningRival() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        return Conflicts.all.first { running.contains($0) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Runs BEFORE the menu is on screen, so growing it here is safe — and it
        // must happen before isMenuOpen, which suppresses exactly that.
        showCachedUpdate()
        isMenuOpen = true
        refreshPermissionUI()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        brightnessItem.isHidden = !ddc.isAvailable
        grabBrightnessItem.isHidden = !ddc.isAvailable
        // Offer the Input Monitoring fix only when brightness is wanted but the
        // HID capture can't run for lack of it.
        inputMonitoringItem.isHidden = !(ddc.isAvailable && wantsBrightnessGrab
                                         && !BrightnessKeyListener.accessGranted)
        if ddc.isAvailable { brightnessSlider.doubleValue = Double(ddc.percent) }
        if let rival = runningRival() {
            conflictItem.title = Conflicts.problem(for: rival)
            conflictItem.toolTip = "Fix: \(Conflicts.fixHint(for: rival))"
            conflictItem.isHidden = false
        } else {
            conflictItem.isHidden = true
        }
        // Re-read control.json on open so overrides added/cleared from the CLI
        // for a *silent* app (which never moves status.json, so statusChanged
        // wouldn't fire) are reflected — chiefly the "Reset App Volumes" row's
        // visibility, which is driven by control.json, not the roster.
        renderApps(lastApps, hasOverrides: !ControlOps.current().apps.isEmpty)
        // A machine that never restarts would otherwise never check again.
        checkForUpdate()
    }

    // MARK: status.json -> UI (the visual layer; reacts to changes from ANY frontend)

    // Compute the "Output: …" menu row's (title, enabled, tooltip) from plain values in one
    // exhaustive switch — no force-unwraps, one assignment site instead of a 4-way if/else.
    private func updateDeviceItem(running: Bool, pipelineOK: Bool, reason: String, device: String) {
        let title: String, enabled: Bool, toolTip: String?
        switch (running, pipelineOK) {
        case (false, _):
            title = "Daemon not running"; enabled = false; toolTip = nil
        case (true, false) where reason == "no-device":
            title = "No output device"; enabled = false; toolTip = nil
        case (true, false):
            // Permission is the most likely cause, but the daemon can't distinguish it
            // from other capture failures — say so honestly and still make the row the fix.
            title = "Audio capture not working — click to fix"; enabled = true
            toolTip = "Most likely the System Audio Recording permission."
                + (reason.isEmpty ? "" : " Daemon reports: \(reason)")
        case (true, true):
            title = "Output: \(device.isEmpty ? "default device" : device)"; enabled = false; toolTip = nil
        }
        deviceItem.title = title
        deviceItem.isEnabled = enabled
        deviceItem.toolTip = toolTip
    }

    private func statusChanged(_ status: Status?) {
        guard !isQuitting else { return }
        let running = status?.running ?? false
        lastStatusRunning = running
        // While the daemon is down, show what control.json will apply when it's back.
        let control = ControlOps.current()
        let gain = running ? (status?.gain ?? control.gain) : control.gain
        let muted = running ? (status?.muted ?? control.muted) : control.muted

        lastPipelineOK = status?.pipeline ?? false
        lastShownGain = gain
        lastShownMuted = muted
        renderStatusItem()
        // Don't fight the user's hand: skip the echo while the knob is being dragged.
        if !(slider.cell?.isHighlighted ?? false) {
            slider.doubleValue = Double(gain)
        }
        headerLevelLabel.stringValue = !running ? "off" : muted ? "Muted" : "\(gain)%"
        muteItem.state = muted ? .on : .off
        updateDeviceItem(running: running, pipelineOK: lastPipelineOK,
                         reason: status?.reason ?? "", device: status?.device ?? "")

        // Per-app rows reflect the daemon's roster; the reset affordance appears
        // whenever any override exists in control.json (even for a silent app).
        lastApps = running ? (status?.apps ?? []) : []
        renderApps(lastApps, hasOverrides: !control.apps.isEmpty)

        guard running else {
            lastLevel = nil
            return
        }
        // HUD only when the level actually moved AND audio is actually being
        // rendered — never fake feedback for a dead pipeline.
        if lastPipelineOK, let last = lastLevel, last != (gain, muted) {
            hud.show(gain: gain, muted: muted)
        }
        lastLevel = (gain, muted)
    }

    /// Renders icon, level, distress badge (⚠︎ when something needs the user)
    /// and tooltip from the stored state. Called from statusChanged and the
    /// key-tap watchdog so problems surface without opening the menu.
    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let healthy = lastStatusRunning && lastPipelineOK
        let keysDead = wantsKeyGrab && keyTap?.isRunning != true
        let badge = keysDead || (lastStatusRunning && !lastPipelineOK) ? " ⚠︎" : ""
        // The level-bars mark: crossed-out when muted, and colour or monochrome
        // template to match the user's icon setting (so mute isn't the odd one
        // out, and never a colour emoji).
        button.image = wantsMonoIcon
            ? (lastShownMuted ? Self.levelBarsMutedIcon : Self.levelBarsIcon)
            : (lastShownMuted ? Self.levelBarsColorMutedIcon : Self.levelBarsColorIcon)
        button.imagePosition = .imageLeft
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.title = " \(lastShownMuted ? "Muted" : "\(lastShownGain)%")" + badge
        button.appearsDisabled = !healthy
        if !lastStatusRunning {
            button.toolTip = "Loudini — daemon not running"
        } else if !lastPipelineOK {
            button.toolTip = "Loudini — no audio control: grant System Audio Recording (open the menu)"
        } else if keysDead {
            button.toolTip = "Loudini — volume keys need Accessibility (open the menu)"
        } else {
            button.toolTip = "Loudini — \(lastShownMuted ? "muted" : "\(lastShownGain)%")"
        }
    }

    // MARK: user actions -> control.json (shared atomic writers)

    private func writeControlChange(_ op: @escaping () throws -> Control) {
        writeQueue.async {
            do { _ = try op() }
            catch { NSLog("Loudini: control.json write failed: %@", error.localizedDescription) }
        }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let gain = Int(sender.doubleValue.rounded())
        headerLevelLabel.stringValue = "\(gain)%"  // instant feedback; status echo follows
        writeControlChange { try ControlOps.set(gain: gain) }
    }

    @objc private func muteClicked() {
        writeControlChange { try ControlOps.toggleMute() }
    }

    // MARK: per-app rows (Phase 3)

    /// A per-row key that's unique across the roster. Scoping by pid keeps two
    /// entries that share a bundle id (or share the empty "" of bundle-less
    /// sources) from colliding in `appRows` — a collision would overwrite one
    /// row's handle and orphan its menu item on the next update/removal.
    private static func rowKey(_ a: AppEntry) -> String {
        a.bundleID.isEmpty ? "pid:\(a.pid)" : "\(a.bundleID)#\(a.pid)"
    }

    /// Reconcile the per-app rows with the daemon's roster. Reuses existing row
    /// views when the set of apps is unchanged (only refreshing values, so a
    /// live drag isn't interrupted by a gain echo) and rebuilds only when apps
    /// actually appear/disappear.
    private func renderApps(_ apps: [AppEntry], hasOverrides: Bool) {
        guard let menu = statusItem.menu else { return }
        emptyAppsItem.isHidden = !apps.isEmpty
        // Only offer the reset when there's actually an override to clear.
        resetAppsItem.isHidden = !hasOverrides

        let keys = apps.map(Self.rowKey)
        if keys == shownAppKeys {
            // Rows are invisible while the menu is closed, and StatusWatcher fires ~5x/s
            // during a ramp — skip the per-row icon/label refresh until the menu is on
            // screen. menuWillOpen sets isMenuOpen then re-renders, so an open menu is current.
            if isMenuOpen {
                for a in apps { updateAppRow(appRows[Self.rowKey(a)], a) }
            }
            return
        }
        // Structure changed — tear the old rows out and rebuild in roster order,
        // inserting just above the reset item.
        for row in appRows.values { menu.removeItem(row.item) }
        appRows.removeAll()
        var idx = menu.index(of: resetAppsItem)
        for a in apps {
            let row = makeAppRow(a)
            if idx >= 0 { menu.insertItem(row.item, at: idx); idx += 1 }
            appRows[Self.rowKey(a)] = row
            updateAppRow(row, a)
        }
        shownAppKeys = keys
    }

    private func makeAppRow(_ a: AppEntry) -> AppRowViews {
        let item = NSMenuItem()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 42))

        let icon = NSImageView(frame: NSRect(x: 16, y: 21, width: 18, height: 18))
        icon.imageScaling = .scaleProportionallyUpOrDown

        let name = NSTextField(labelWithString: a.name)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 40, y: 23, width: 196, height: 15)

        let mute = NSButton(frame: NSRect(x: 244, y: 20, width: 22, height: 22))
        mute.isBordered = false
        mute.bezelStyle = .regularSquare
        mute.imagePosition = .imageOnly
        mute.target = self
        mute.action = #selector(appMuteClicked(_:))

        let slider = NSSlider(value: Double(a.gain), minValue: 0, maxValue: 100,
                              target: self, action: #selector(appSliderMoved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 40, y: 2, width: 226, height: 20)

        // Bundle id rides on the controls so the action knows which app to write.
        // Bundle-less sources can't be targeted (no stable key) — disable them.
        let addressable = !a.bundleID.isEmpty
        slider.identifier = NSUserInterfaceItemIdentifier(a.bundleID)
        mute.identifier = NSUserInterfaceItemIdentifier(a.bundleID)
        slider.isEnabled = addressable
        mute.isEnabled = addressable
        if !addressable {
            let tip = "No bundle id — per-app volume can't target this source"
            slider.toolTip = tip
            mute.toolTip = tip
        }

        row.addSubview(icon)
        row.addSubview(name)
        row.addSubview(mute)
        row.addSubview(slider)
        item.view = row
        return AppRowViews(item: item, icon: icon, name: name, slider: slider, mute: mute)
    }

    private func updateAppRow(_ row: AppRowViews?, _ a: AppEntry) {
        guard let row else { return }
        row.name.stringValue = a.name
        // Dim a lingering (idle) app so the live ones read first.
        row.name.textColor = a.active ? .labelColor : .secondaryLabelColor
        // pid_t(exactly:) — never trap on an out-of-range pid; nil falls back.
        row.icon.image = NSRunningApplication(processIdentifier: pid_t(exactly: a.pid) ?? -1)?.icon
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        // Don't fight the user's hand: skip the echo while this slider is dragged.
        if !(row.slider.cell?.isHighlighted ?? false) { row.slider.doubleValue = Double(a.gain) }
        row.mute.image = NSImage(
            systemSymbolName: a.muted ? "speaker.slash.fill" : "speaker.fill",
            accessibilityDescription: a.muted ? "Unmute \(a.name)" : "Mute \(a.name)")
        row.mute.contentTintColor = a.muted ? .systemRed : .secondaryLabelColor
    }

    @objc private func appSliderMoved(_ sender: NSSlider) {
        guard let bid = sender.identifier?.rawValue, !bid.isEmpty else { return }
        let gain = Int(sender.doubleValue.rounded())
        writeControlChange { try ControlOps.setApp(bid, gain: gain) }
    }

    @objc private func appMuteClicked(_ sender: NSButton) {
        guard let bid = sender.identifier?.rawValue, !bid.isEmpty else { return }
        writeControlChange { try ControlOps.toggleAppMute(bid) }
    }

    @objc private func resetAppsClicked() {
        writeControlChange { try ControlOps.resetApps() }
    }

    private func handleVolumeKey(_ key: VolumeKeyTap.Key, fine: Bool) {
        let step = fine ? Self.fineStep : Self.step
        switch key {
        case .up: writeControlChange { try ControlOps.nudge(step) }
        case .down: writeControlChange { try ControlOps.nudge(-step) }
        case .mute: writeControlChange { try ControlOps.toggleMute() }
        case .brightnessUp: nudgeBrightness(step)
        case .brightnessDown: nudgeBrightness(-step)
        }
    }

    private func nudgeBrightness(_ delta: Int) {
        ddc.nudge(delta) { [weak self] percent in
            guard let self, !self.isQuitting else { return }
            self.brightnessSlider.doubleValue = Double(percent)
            self.hud.show(brightnessPercent: percent)
        }
    }

    @objc private func brightnessSliderMoved(_ sender: NSSlider) {
        ddc.set(Int(sender.doubleValue.rounded())) { _ in }
    }

    @objc private func toggleGrabBrightness() {
        wantsBrightnessGrab.toggle()
        grabBrightnessItem.state = wantsBrightnessGrab ? .on : .off
    }

    /// Register the app for Input Monitoring (adds it to the list + prompts),
    /// then open that settings pane so the user can flip the toggle.
    @objc private func enableInputMonitoring() {
        BrightnessKeyListener.requestAccess()
        brightnessKeys?.start()  // ensure the manager is open so macOS lists us
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when the built-in panel is active — macOS should keep the
    /// brightness keys then; Loudini only owns them for external-only setups.
    private static func builtInDisplayActive() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    // MARK: volume-key tap + Accessibility permission

    private func setupKeyTap(promptIfNeeded: Bool) {
        guard wantsKeyGrab, keyTap?.isRunning != true else { return }

        let trusted: Bool
        if promptIfNeeded {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }

        if trusted {
            UserDefaults.standard.set(true, forKey: "wasEverAXTrusted")
            let tap = VolumeKeyTap { [weak self] key, fine in self?.handleVolumeKey(key, fine: fine) }
            // Only own the keys while audio is actually under our control;
            // otherwise pass them to macOS so its native (crossed-out) HUD
            // gives an honest "this does nothing" signal. Both closures run
            // on the main run loop — no race.
            tap.shouldConsume = { [weak self] in
                guard let self else { return false }
                return self.lastStatusRunning && self.lastPipelineOK
            }
            // Brightness is owned solely by the HID listener (BrightnessKeyListener):
            // in the only case Loudini drives brightness — external DDC display, no
            // built-in — macOS never emits the NX brightness event anyway, so routing
            // it here too would just double-nudge on the rare setup where it does fire.
            // Leave shouldConsumeBrightness at its default (false): the NX tap is volume-only.
            if tap.start() {
                keyTap = tap
            } else {
                NSLog("Loudini: event tap creation failed despite Accessibility trust — watchdog will retry")
            }
        }
        // If not trusted: degrade gracefully (menu + slider keep working);
        // the watchdog below picks the keys up the moment trust appears.
        refreshPermissionUI()
    }

    /// 3 s watchdog: heals a revoked grant, a macOS-disabled tap, or a failed
    /// creation, and keeps the permission UI + distress badge current.
    private func startKeyTapWatchdog() {
        axRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !self.isQuitting else { return }
            let trusted = AXIsProcessTrusted()
            if trusted { UserDefaults.standard.set(true, forKey: "wasEverAXTrusted") }
            if self.wantsKeyGrab, let tap = self.keyTap, !trusted || !tap.isEnabled {
                NSLog("Loudini: key tap lost (trusted=%d, enabled=%d) — rebuilding",
                      trusted ? 1 : 0, tap.isEnabled ? 1 : 0)
                tap.stop()
                self.keyTap = nil
            }
            if self.wantsKeyGrab, self.keyTap == nil, trusted {
                self.setupKeyTap(promptIfNeeded: false)
            }
            // Picks the brightness keys up once Input Monitoring is granted,
            // without needing a relaunch. No-op while it's already running.
            if self.wantsBrightnessGrab { self.brightnessKeys?.start() }
            self.refreshPermissionUI()
            self.renderStatusItem()
        }
    }

    private func refreshPermissionUI() {
        let trusted = AXIsProcessTrusted()
        accessibilityItem.isHidden = trusted
        fixPermissionItem.isHidden = trusted
        // Stale grant (we were trusted before a rebuild changed our ad-hoc
        // identity) reads differently from a never-granted install.
        fixPermissionItem.title = UserDefaults.standard.bool(forKey: "wasEverAXTrusted")
            ? "Repair Volume-Key Permission (app was rebuilt)…"
            : "Fix Volume-Key Permission…"
        grabKeysItem.title = trusted || !wantsKeyGrab
            ? "Grab Volume Keys"
            : "Grab Volume Keys (needs Accessibility)"
        grabKeysItem.state = wantsKeyGrab ? .on : .off
    }

    @objc private func toggleGrabKeys() {
        wantsKeyGrab.toggle()
        if wantsKeyGrab {
            setupKeyTap(promptIfNeeded: true)
        } else {
            keyTap?.stop()
            keyTap = nil
            refreshPermissionUI()
        }
        renderStatusItem()
    }

    @objc private func toggleMonoIcon() {
        wantsMonoIcon.toggle()
        UserDefaults.standard.set(wantsMonoIcon, forKey: "monoIcon")
        monoIconItem.state = wantsMonoIcon ? .on : .off
        renderStatusItem()
    }

    // MARK: update check (GitHub releases, look-only)

    private static let latestReleaseAPI = "https://api.github.com/repos/pimmesz/Loudini/releases/latest"
    private static let latestReleasePage = "https://github.com/pimmesz/Loudini/releases/latest"

    @objc private func toggleUpdateCheck() {
        wantsUpdateCheck.toggle()
        UserDefaults.standard.set(wantsUpdateCheck, forKey: "autoUpdateCheck")
        updateCheckItem.state = wantsUpdateCheck ? .on : .off
        // Off means off: no call, and the banner goes with it. Back on brings
        // the last known tag straight back, without waiting for the next check.
        if wantsUpdateCheck {
            showCachedUpdate()
            checkForUpdate()
        } else {
            // Off means off NOW: kill any transfer already in the air, or it would
            // keep talking to GitHub (and record its answer) after the opt-out.
            updateTask?.cancel()
            updateTask = nil
            updateItem.isHidden = true
        }
    }

    /// Re-show the tag GitHub last reported, without asking again.
    private func showCachedUpdate() {
        if let seen = UserDefaults.standard.string(forKey: "lastSeenTag") { showUpdateRow(seen) }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc private func updateClicked() {
        NSWorkspace.shared.open(URL(string: Self.latestReleasePage)!)
    }

    /// Ephemeral (no cache, no cookies) and time-bounded, so a proxy that trickles
    /// bytes forever can't leave a task alive: URLSession's default resource timeout
    /// is SEVEN DAYS, and the request timeout is only an idle timer.
    private static let updateSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        // Nothing to accept and nothing to send back: a public unauthenticated
        // endpoint has no business setting a cookie on us.
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    /// The in-flight check, so switching the toggle off actually stops it.
    private var updateTask: URLSessionDataTask?

    /// Ask GitHub for the latest release tag, at most once a day. Unauthenticated,
    /// no query params, no auth, nothing identifying the user.
    /// We set User-Agent to a bare "Loudini" deliberately: GitHub rejects a request
    /// without one (403), and CFNetwork's default would otherwise announce the exact
    /// Darwin kernel build — this sends strictly less.
    /// Any failure is silent on purpose — a menu-bar utility must not nag.
    private func checkForUpdate() {
        guard wantsUpdateCheck else { return }
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - lastCheck >= 24 * 60 * 60 else { return }
        // Stamp before the call, not after, so a failing network can't turn the
        // rate limit into a check on every menu open.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        var request = URLRequest(url: URL(string: Self.latestReleaseAPI)!)
        request.setValue("Loudini", forHTTPHeaderField: "User-Agent")
        // Pin these too: left alone, CFNetwork fills Accept-Language from the
        // user's language list, which is a fingerprint of its own.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = Self.updateSession.dataTask(with: request) { data, _, _ in
            // A release JSON is a few KB; anything huge is not what we asked for.
            guard let data, data.count < 1_000_000, let tag = Self.parseTag(data) else { return }
            UserDefaults.standard.set(tag, forKey: "lastSeenTag")
            DispatchQueue.main.async { [weak self] in self?.showUpdateRow(tag) }
        }
        updateTask = task
        task.resume()
    }

    /// tag_name out of the release JSON (e.g. "v0.4.0"), or nil if it isn't there.
    private static func parseTag(_ data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let tag = (json as? [String: Any])?["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag
    }

    /// Show the banner only for a strictly newer release; hide it otherwise.
    private func showUpdateRow(_ tag: String) {
        guard !isQuitting else { return }
        let shouldShow = wantsUpdateCheck && Self.isNewer(tag, than: Self.appVersion)
        if shouldShow { updateItem.title = "Update available: \(tag)" }
        // Never change the menu's HEIGHT while it is on screen — in either
        // direction. A reply landing mid-click would shift every row below it,
        // including Quit, under the pointer. The tag is cached, so the next open
        // reflects whatever this check found.
        guard !isMenuOpen else { return }
        updateItem.isHidden = !shouldShow
    }

    /// Numeric components of a version, tolerating a leading "v" and trailing
    /// junk on a component ("v0.4.0" -> [0, 4, 0]).
    private static func versionParts(_ version: String) -> [Int] {
        let digits = version.hasPrefix("v") || version.hasPrefix("V")
            ? version.dropFirst() : version[...]
        return digits.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// True when `remote` is strictly greater than `local`. Missing components
    /// count as zero, so "0.3" and "0.3.0" compare equal.
    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = versionParts(remote), l = versionParts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openAudioCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Repairs the "Settings shows the toggle ON but macOS denies us" state
    /// that ad-hoc re-signing causes: wipe our own TCC Accessibility entry,
    /// then ask again so a fresh prompt appears.
    @objc private func fixAccessibilityClicked() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility",
                           Bundle.main.bundleIdentifier ?? "gg.pim.loudini.menubar"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, !self.isQuitting else { return }
                self.keyTap?.stop()
                self.keyTap = nil
                self.setupKeyTap(promptIfNeeded: true)
            }
        }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Loudini: could not change login item: %@", error.localizedDescription)
        }
        loginItem.state = service.status == .enabled ? .on : .off
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: daemon ownership

    private func ensureDaemon() {
        if let d = daemon, d.isRunning { return }
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/gg.pim.loudini.plist"
        let hasAgent = FileManager.default.fileExists(atPath: plistPath)
        // pgrep/launchctl block on waitUntilExit — keep them off the main
        // thread (the event-tap callback lives there). The daemon's flock
        // makes any race here harmless: a redundant instance exits by itself.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if Self.isDaemonProcessAlive() { return }
            if hasAgent {
                // The user installed the LaunchAgent — revive it rather than
                // spawning our own: kickstart restarts a loaded job, bootstrap
                // covers "plist present but never loaded".
                if Self.runLaunchctl(["kickstart", "gui/\(getuid())/gg.pim.loudini"]) != 0 {
                    _ = Self.runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
                }
                // A plist pointing at a moved/deleted binary makes both calls
                // useless (or "succeed" into a job that can never run). Probe
                // once after a grace period and fall back to our bundled
                // daemon — the flock arbitrates if the agent comes up too.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    guard !Self.isDaemonProcessAlive() else { return }
                    NSLog("Loudini: LaunchAgent did not produce a daemon — falling back to the bundled one")
                    DispatchQueue.main.async {
                        guard let self, !self.isQuitting else { return }
                        if let d = self.daemon, d.isRunning { return }
                        self.spawnDaemon()
                    }
                }
                return
            }
            DispatchQueue.main.async {
                guard let self, !self.isQuitting else { return }
                if let d = self.daemon, d.isRunning { return }
                self.spawnDaemon()
            }
        }
    }

    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// True when any of OUR loudini-helper processes is up (scoped to this
    /// user — another account's daemon must not suppress ours). A CLI
    /// invocation can match too — that false positive only delays the spawn
    /// by one 5 s retry tick.
    private static func isDaemonProcessAlive() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-U", "\(getuid())", "-x", "loudini-helper"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func spawnDaemon() {
        // The daemon ships inside the bundle, next to our own executable.
        let url = Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("loudini-helper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            NSLog("Loudini: bundled daemon missing at %@ — run menubar/build-app.sh", url.path)
            return
        }
        let p = Process()
        p.executableURL = url
        if let log = daemonLogHandle() {
            p.standardOutput = log
            p.standardError = log
        }
        // No immediate respawn on exit: the 5 s daemonRetryTimer recovers it,
        // which doubles as backoff if the daemon dies instantly every time.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.daemon = nil }
        }
        do {
            try p.run()
            daemon = p
            NSLog("Loudini: spawned daemon pid %d", p.processIdentifier)
        } catch {
            NSLog("Loudini: cannot start daemon: %@", error.localizedDescription)
        }
    }

    private func daemonLogHandle() -> FileHandle? {
        let url = configDir.appendingPathComponent("daemon.log")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
