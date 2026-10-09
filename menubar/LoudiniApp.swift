// LoudiniApp.swift: the Loudini menu-bar app. It grabs the hardware volume keys
// (VolumeKeyTap), shows the live level in the menu bar + a dropdown slider, and
// pops a HUD on every level change (HUDWindow). All state comes from the
// daemon's status.json; all changes go through the shared atomic control.json
// writers in helper/ControlFile.swift: the exact code the CLI uses.
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
    private static let step = 6  // % per key press: matches the CLI and Stream Deck
    private static let fineStep = 1  // % per key press when Shift is held (small adjust)
    private static let softwareVolumeTip = "100% leaves the level unchanged; 50% is 25 dB quieter; 0% is silent. "
        + "Above 0%, each point changes the level by 0.5 dB."
    private static let volumeSliderTip = "For outputs without their own volume control: " + softwareVolumeTip
        + "\nOutputs with their own volume control use the device's scale."
        + "\nTip: hold Shift while you press a volume key to change the volume by one point."

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
    /// Shown while this copy runs from a disk image or a translocated folder, where it
    /// can neither update itself nor start at login.
    private var outsideApplicationsItem: NSMenuItem!
    private let isOutsideApplications: Bool = {
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") { return true }
        // A mounted disk image is read-only; a copy on a writable external drive updates fine.
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }()
    private var brightnessItem: NSMenuItem!

    // Per-app volume section (Phase 3). One row per status.json.apps entry, built
    // dynamically between `appsSeparator` and `resetAppsItem`.
    private var appsSeparator: NSMenuItem!
    private var emptyAppsItem: NSMenuItem!
    /// Keeps "Reset App Volumes" a step away from the last app slider.
    private var resetSeparator: NSMenuItem!
    private var resetAppsItem: NSMenuItem!
    /// Live row views keyed by roster row key (bundle id, or a pid-scoped key for
    /// bundle-less sources). Reused across renders so a drag survives a gain echo.
    private var appRows: [String: AppRowViews] = [:]
    /// The ordered row keys currently shown: a cheap structural-change check.
    private var shownAppKeys: [String] = []

    private struct AppRowViews {
        let item: NSMenuItem
        let icon: NSImageView
        let name: NSTextField
        let slider: NSSlider
        let mute: NSButton
        let level: NSButton
        let reset: NSButton
    }

    /// When on, the menu-bar logo renders as a template (single colour that
    /// follows the menu-bar text), so it blends in with other monochrome icons.
    private var wantsMonoIcon = UserDefaults.standard.bool(forKey: "monoIcon")

    /// In-app updates; created at launch, before the menu reads its toggle state.
    private var updater: Updater!
    private var brightnessSlider: NSSlider!

    /// External-monitor brightness over DDC (no daemon involved).
    private let ddc = DDCBrightness()
    /// Both key toggles are remembered, so turning one off sticks across launches
    /// (otherwise the permission prompt and the warning badge come back every login).
    private var wantsBrightnessGrab = UserDefaults.standard.object(forKey: "grabBrightnessKeys") as? Bool ?? true
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
    private var wantsKeyGrab = UserDefaults.standard.object(forKey: "grabVolumeKeys") as? Bool ?? true
    /// Why the pipeline is down, from status.json ("render stalled", "no-device", ...).
    private var lastReason = ""
    /// An app that re-captures system audio is running (Conflicts.captureRivals).
    private var isCaptureRivalRunning = false
    /// The Accessibility repair ran this session; only then offer the Settings pane too.
    private var didAttemptAXFix = false
    /// Last (gain, muted) seen running: HUD fires only when the level moves.
    private var lastLevel: (gain: Int, muted: Bool)?

    /// Control writes happen off the main thread (tap callback + UI must not block on IO).
    private let writeQueue = DispatchQueue(label: "gg.pim.loudini.menubar.write", qos: .userInitiated)

    /// The running build's version, straight from Info.plist. Never hardcoded:
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

    /// Loudini's mark: four rounded level bars, a volume-control glyph that
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
    /// the slash legible over them). Monochrome template: mute reads the same
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
        // First, before anything starts from this copy: a disk-image copy that spawned the
        // daemon would hold daemon.lock, and the intro below is shown only once.
        if offerMoveToApplications() { return }
        updater = Updater()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        renderStatusItem()

        updater.onReady = { [weak self] version in self?.showUpdateRow(version) }

        hud = HUDWindow()
        showPermissionIntroOnce()
        ensureDaemon()
        // Recover a missing daemon while status shows it down (covers crashes,
        // and spawn races; the daemon's own flock makes a redundant spawn harmless,
        // since it waits to take over rather than run a second engine).
        daemonRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.isQuitting, !self.lastStatusRunning else { return }
            self.ensureDaemon()
        }

        statusWatcher = StatusWatcher { [weak self] status in self?.statusChanged(status) }
        statusWatcher.start()

        setupKeyTap(promptIfNeeded: true)
        startKeyTapWatchdog()

        // Displays come and go: re-enumerate the DDC targets when they do.
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

    /// One plain explanation before the first permission dialogs, so they don't arrive out
    /// of nowhere from an app with no window. Shown once, and only on a fresh install.
    /// Offer to move a copy running from a disk image into /Applications, the only place it
    /// can update itself. True when the move started and this copy is quitting.
    private func offerMoveToApplications() -> Bool {
        guard isOutsideApplications else { return false }
        let alert = NSAlert()
        alert.messageText = "Move Loudini to Applications?"
        alert.informativeText = "Loudini can only update itself and start at login from your Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let target = URL(fileURLWithPath: "/Applications/Loudini.app")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            let confirm = NSAlert()
            confirm.messageText = "Replace the Loudini in Applications?"
            confirm.informativeText = "The copy there goes to the Trash. If it is running, it quits first."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return false }
        }
        // Any other running copy keeps daemon.lock, and the moved copy's engine would only
        // wait behind it, so every other copy must be gone before the move.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if others.contains(where: { !$0.isTerminated }) {
            return moveFailed("Another Loudini is still running. Quit it from its menu, then open this copy again.")
        }
        // Copy next to the target first, so a failed copy never costs the working install.
        let staging = URL(fileURLWithPath: "/Applications/.Loudini-moving-\(me).app")
        var isStaged = false
        do {
            try fm.copyItem(at: Bundle.main.bundleURL, to: staging)
            isStaged = true
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            // A half-copied staging bundle is useless; a complete one is kept only when the
            // old copy is already in the Trash, because then it is the only copy left.
            if !isStaged || fm.fileExists(atPath: target.path) { try? fm.removeItem(at: staging) }
            return moveFailed("\(error.localizedDescription) Drag Loudini into Applications yourself, then open it from there.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, error in
            DispatchQueue.main.async {
                // This copy set nothing up, so it quits either way; on a failed launch it says why first.
                if let error {
                    _ = self.moveFailed("Loudini is now in Applications but did not open "
                        + "(\(error.localizedDescription)). Open it from Applications.")
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private func moveFailed(_ reason: String) -> Bool {
        let failed = NSAlert()
        failed.messageText = "Loudini could not be moved"
        failed.informativeText = reason
        failed.runModal()
        return false
    }

    private func showPermissionIntroOnce() {
        guard !UserDefaults.standard.bool(forKey: "shownPermissionIntro"), !AXIsProcessTrusted() else { return }
        UserDefaults.standard.set(true, forKey: "shownPermissionIntro")
        let alert = NSAlert()
        alert.messageText = "Loudini needs two permissions"
        alert.informativeText = "Accessibility lets Loudini use your volume keys. "
            + "System Audio Recording lets Loudini change the volume of your sound. "
            + "Loudini does not record or save any sound."
        alert.addButton(withTitle: "Continue")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        keyTap?.stop()
        brightnessKeys?.stop()
        statusWatcher?.stop()  // nil when a disk-image copy quits right after moving itself
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
        versionLabel.textColor = .secondaryLabelColor
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

        // Volume row, Sound-menu style: quiet icon, slider, loud icon.
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
        slider.setAccessibilityLabel("Volume")
        slider.toolTip = Self.volumeSliderTip
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
        brightnessSlider.setAccessibilityLabel("Brightness")
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

        deviceItem = NSMenuItem(title: "Volume engine is not running",
                                action: #selector(openAudioCaptureSettings), keyEquivalent: "")
        deviceItem.target = self
        deviceItem.isEnabled = false  // becomes clickable only in the "fix permission" state
        deviceItem.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)
        menu.addItem(deviceItem)

        // Shown only when a known media-key grabber is running (menuWillOpen).
        // Enabled (full contrast) although it has no action: it is a message to read.
        conflictItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        conflictItem.isEnabled = true
        conflictItem.isHidden = true
        conflictItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                     accessibilityDescription: "warning")
        menu.addItem(conflictItem)

        // Volume-key permission fix, next to the other "something is wrong" rows.
        // One row; the Settings pane is offered only once the repair already ran.
        fixPermissionItem = NSMenuItem(title: "Allow Volume Keys…",
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

        // Per-app volume section. Rows are inserted at runtime (renderApps)
        // between this separator and the reset item; the empty-state line shows
        // when nothing is playing, matching macOS's own Sound per-app list.
        appsSeparator = .separator()
        menu.addItem(appsSeparator)
        emptyAppsItem = NSMenuItem(title: "No apps are playing audio", action: nil, keyEquivalent: "")
        emptyAppsItem.isEnabled = false
        menu.addItem(emptyAppsItem)
        resetSeparator = .separator()
        resetSeparator.isHidden = true
        menu.addItem(resetSeparator)
        resetAppsItem = NSMenuItem(title: "Reset App Volumes",
                                   action: #selector(resetAppsClicked), keyEquivalent: "")
        resetAppsItem.target = self
        resetAppsItem.toolTip = "Sets every app back to 100% and unmutes them."
        resetAppsItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        resetAppsItem.isHidden = true
        menu.addItem(resetAppsItem)

        menu.addItem(.separator())

        grabKeysItem = NSMenuItem(title: "Use Volume Keys",
                                  action: #selector(toggleGrabKeys), keyEquivalent: "")
        grabKeysItem.target = self
        grabKeysItem.state = wantsKeyGrab ? .on : .off
        grabKeysItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        menu.addItem(grabKeysItem)

        grabBrightnessItem = NSMenuItem(title: "Use Brightness Keys",
                                        action: #selector(toggleGrabBrightness), keyEquivalent: "")
        grabBrightnessItem.target = self
        grabBrightnessItem.state = wantsBrightnessGrab ? .on : .off
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

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
        // A login item would point at a disk image that is gone after the next eject.
        loginItem.isEnabled = !isOutsideApplications
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
        updateCheckItem.state = updater.isAutomatic ? .on : .off
        updateCheckItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(updateCheckItem)

        // Shown only once Sparkle has downloaded a newer release.
        updateItem = NSMenuItem(title: "", action: #selector(installUpdateClicked), keyEquivalent: "")
        updateItem.target = self
        updateItem.toolTip = "Installs the downloaded update and restarts Loudini. "
            + "Your settings and permissions stay."
        updateItem.isHidden = true
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updateItem)

        outsideApplicationsItem = NSMenuItem(title: "Updates are off: Loudini is not in Applications",
                                             action: nil, keyEquivalent: "")
        outsideApplicationsItem.isEnabled = false
        outsideApplicationsItem.isHidden = !isOutsideApplications
        outsideApplicationsItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        menu.addItem(outsideApplicationsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Loudini", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// The first running app known to fight with Loudini, or nil. Which apps those are,
    /// and what to tell the user about each, lives in helper/Conflicts.swift, the same
    /// list `loudini doctor` checks, so the two never give conflicting advice.
    private func runningRival() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        return Conflicts.all.first { running.contains($0) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Runs BEFORE the menu is on screen, so growing it here is safe, and it
        // must happen before isMenuOpen, which suppresses exactly that.
        updateItem.isHidden = updater.readyVersion == nil
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
            // The fix is visible on the row itself, not hidden in a hover tooltip.
            conflictItem.subtitle = Conflicts.fixHint(for: rival)
            conflictItem.isHidden = false
        } else {
            conflictItem.isHidden = true
        }
        // Re-read control.json on open so overrides added/cleared from the CLI
        // for a *silent* app (which never moves status.json, so statusChanged
        // wouldn't fire) are reflected, chiefly the "Reset App Volumes" row's
        // visibility, which is driven by control.json, not the roster.
        renderApps(lastApps, hasOverrides: !ControlOps.current().apps.isEmpty)
    }

    // MARK: status.json -> UI (the visual layer; reacts to changes from ANY frontend)

    // Compute the "Output: …" menu row's (title, enabled, tooltip) from plain values in one
    // exhaustive switch: no force-unwraps, one assignment site instead of a 4-way if/else.
    private func updateDeviceItem(running: Bool, pipelineOK: Bool, reason: String, device: String,
                                  daemonVersion: String) {
        let title: String, enabled: Bool, toolTip: String?
        switch (running, pipelineOK) {
        case (false, _):
            title = "Volume engine is not running"; enabled = false
            toolTip = "Loudini tries to start it every few seconds."
        case (true, false) where reason == "no-device":
            title = "No output device"; enabled = false; toolTip = nil
        case (true, false) where reason == "render stalled":
            // Not a permission problem: the daemon tore its audio path down and rebuilds
            // it by itself. Nothing to click, and the same advice `loudini doctor` gives.
            title = "Volume control is restarting"; enabled = false
            toolTip = "Loudini lost control of the sound and will try again by itself. "
                + "This can take up to 5 minutes. Until then, the sound plays without Loudini's volume."
        case (true, false):
            // Permission is the most likely cause, but the daemon can't distinguish it
            // from other capture failures, so the row hedges and still opens the fix.
            title = "Volume control is off. Check permission…"; enabled = true
            toolTip = "Loudini most likely needs System Audio Recording. Click to open System Settings, "
                + "then turn on Loudini." + (reason.isEmpty ? "" : " Details: \(reason)")
        case (true, true):
            title = "Output: \(device.isEmpty ? "default device" : device)"; enabled = false
            // Another Loudini copy (LaunchAgent, Stream Deck plugin) can own the audio engine.
            // An empty version is a daemon too old to report one.
            toolTip = daemonVersion.isEmpty || daemonVersion == loudiniVersion ? nil
                : "The audio engine is build \(daemonVersion), this app is \(loudiniVersion). "
                + "Quit other Loudini copies (LaunchAgent, Stream Deck plugin), then reopen Loudini."
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
        lastReason = status?.reason ?? ""
        lastShownGain = gain
        lastShownMuted = muted
        renderStatusItem()
        // Don't fight the user's hand: skip the echo while the knob is being dragged.
        if !(slider.cell?.isHighlighted ?? false) {
            slider.doubleValue = Double(gain)
        }
        headerLevelLabel.stringValue = !running ? "Off" : muted ? "Muted" : "\(gain)%"
        // A slider move while Loudini has no control is only saved for later; say so.
        slider.toolTip = running && lastPipelineOK ? Self.volumeSliderTip
            : "Loudini cannot change the volume right now. Your choice is used when it works again."
        muteItem.state = muted ? .on : .off
        updateDeviceItem(running: running, pipelineOK: lastPipelineOK,
                         reason: status?.reason ?? "", device: status?.device ?? "",
                         daemonVersion: status?.version ?? "")

        // Per-app rows reflect the daemon's roster; the reset affordance appears
        // whenever any override exists in control.json (even for a silent app).
        lastApps = running ? (status?.apps ?? []) : []
        renderApps(lastApps, hasOverrides: !control.apps.isEmpty)

        guard running else {
            lastLevel = nil
            return
        }
        // HUD only when the level actually moved AND audio is actually being
        // rendered: never fake feedback for a dead pipeline.
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
        // A render stall rebuilds by itself, so it is not something the user must fix.
        let needsFix = lastStatusRunning && !lastPipelineOK && lastReason != "render stalled"
        let badge = keysDead || needsFix || isCaptureRivalRunning ? " ⚠︎" : ""
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
            button.toolTip = "Loudini: the volume engine is not running. Loudini tries to start it every few seconds."
        } else if !lastPipelineOK {
            button.toolTip = "Loudini: volume control is off. Open the menu to see why."
        } else if isCaptureRivalRunning {
            button.toolTip = "Loudini: another sound app is open. Open the menu to see which."
        } else if keysDead {
            button.toolTip = "Loudini: the volume keys need a permission. Open the menu to fix it."
        } else {
            button.toolTip = "Loudini: \(lastShownMuted ? "muted" : "\(lastShownGain)%")"
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
        // Instant feedback, but only when it is real: otherwise keep "Off" and friends.
        if lastStatusRunning && lastPipelineOK { headerLevelLabel.stringValue = "\(gain)%" }
        writeControlChange { try ControlOps.set(gain: gain) }
    }

    @objc private func muteClicked() {
        writeControlChange { try ControlOps.toggleMute() }
    }

    // MARK: per-app rows (Phase 3)

    /// A per-row key that's stable across roster refreshes. The daemon collapses
    /// each bundle to ONE roster entry keyed by bundle id, so bundle-ful apps key
    /// by bundle id alone: folding the pid in would flap when a background helper
    /// (e.g. a Chrome renderer) churns and tear out a row mid-drag. Bundle-less
    /// sources (empty "") have no stable id, so they still scope by pid; the
    /// daemon keys them the same way, so they can't collide either.
    private static func rowKey(_ a: AppEntry) -> String {
        a.bundleID.isEmpty ? "pid:\(a.pid)" : a.bundleID
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
        resetSeparator.isHidden = !hasOverrides

        let keys = apps.map(Self.rowKey)
        if keys == shownAppKeys {
            // Rows are invisible while the menu is closed, and StatusWatcher fires ~5x/s
            // during a ramp: skip the per-row icon/label refresh until the menu is on
            // screen. menuWillOpen sets isMenuOpen then re-renders, so an open menu is current.
            if isMenuOpen {
                for a in apps { updateAppRow(appRows[Self.rowKey(a)], a) }
            }
            return
        }
        // Structure changed: tear the old rows out and rebuild in roster order,
        // inserting just above the reset item.
        for row in appRows.values { menu.removeItem(row.item) }
        appRows.removeAll()
        var idx = menu.index(of: resetSeparator)
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
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 50))

        let icon = NSImageView(frame: NSRect(x: 16, y: 27, width: 18, height: 18))
        icon.imageScaling = .scaleProportionallyUpOrDown

        let name = NSTextField(labelWithString: a.name)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 40, y: 29, width: 156, height: 15)

        let reset = NSButton(frame: NSRect(x: 204, y: 24, width: 28, height: 24))
        reset.isBordered = false
        reset.bezelStyle = .regularSquare
        reset.imagePosition = .imageOnly
        reset.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        reset.target = self
        reset.action = #selector(appResetClicked(_:))
        reset.toolTip = "Set this app to 100% and unmute it. Other apps keep their settings."

        // At least 24 pt, with a gap above the slider, so a shaky click mutes instead of sliding.
        let mute = NSButton(frame: NSRect(x: 238, y: 24, width: 28, height: 24))
        mute.isBordered = false
        mute.bezelStyle = .regularSquare
        mute.imagePosition = .imageOnly
        mute.target = self
        mute.action = #selector(appMuteClicked(_:))

        let slider = NSSlider(value: Double(a.gain), minValue: 0, maxValue: 100,
                              target: self, action: #selector(appSliderMoved(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 40, y: 2, width: 160, height: 20)
        slider.toolTip = Self.softwareVolumeTip

        let level = NSButton(frame: NSRect(x: 204, y: 0, width: 64, height: 24))
        level.isBordered = false
        level.bezelStyle = .regularSquare
        level.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        level.target = self
        level.action = #selector(appLevelClicked(_:))
        level.toolTip = "Enter an exact volume from 0 to 100.\n" + Self.softwareVolumeTip

        // Bundle id rides on the controls so the action knows which app to write.
        // Bundle-less sources can't be targeted (no stable key): disable them.
        let addressable = !a.bundleID.isEmpty
        slider.identifier = NSUserInterfaceItemIdentifier(a.bundleID)
        mute.identifier = NSUserInterfaceItemIdentifier(a.bundleID)
        level.identifier = NSUserInterfaceItemIdentifier(a.bundleID)
        reset.identifier = NSUserInterfaceItemIdentifier(a.bundleID)
        slider.isEnabled = addressable
        mute.isEnabled = addressable
        level.isEnabled = addressable
        reset.isEnabled = addressable
        if !addressable {
            let tip = "Loudini cannot change the volume of this app on its own."
            slider.toolTip = tip
            mute.toolTip = tip
            level.toolTip = tip
            reset.toolTip = tip
        }

        row.addSubview(icon)
        row.addSubview(name)
        row.addSubview(mute)
        row.addSubview(slider)
        row.addSubview(level)
        row.addSubview(reset)
        item.view = row
        return AppRowViews(item: item, icon: icon, name: name, slider: slider, mute: mute,
                           level: level, reset: reset)
    }

    private func updateAppRow(_ row: AppRowViews?, _ a: AppEntry) {
        guard let row else { return }
        row.name.stringValue = a.name
        row.slider.setAccessibilityLabel("\(a.name) volume")
        row.level.title = "\(a.gain)%"
        row.level.setAccessibilityLabel("Set \(a.name) volume, currently \(a.gain)%")
        row.reset.setAccessibilityLabel("Reset \(a.name) volume and unmute")
        // Dim a lingering (idle) app so the live ones read first.
        row.name.textColor = a.active ? .labelColor : .secondaryLabelColor
        // pid_t(exactly:), never trap on an out-of-range pid; nil falls back.
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

    @objc private func appResetClicked(_ sender: NSButton) {
        guard let bid = sender.identifier?.rawValue, !bid.isEmpty else { return }
        writeControlChange { try ControlOps.resetApp(bid) }
    }

    @objc private func appLevelClicked(_ sender: NSButton) {
        guard let bid = sender.identifier?.rawValue, !bid.isEmpty,
              let app = lastApps.first(where: { $0.bundleID == bid }) else { return }
        // Finish menu tracking before opening a dialog with its own keyboard focus.
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { self.editAppLevel(app) }
    }

    private func editAppLevel(_ app: AppEntry) {
        let alert = NSAlert()
        alert.messageText = "Set \(app.name) volume"
        alert.informativeText = "Enter a whole number from 0 to 100. The app's mute setting stays the same."
        if !lastStatusRunning || !lastPipelineOK {
            alert.informativeText += " Loudini cannot change the volume right now. Your choice is saved for when it works again."
        }
        alert.addButton(withTitle: "Set Volume")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        input.stringValue = String(app.gain)
        input.setAccessibilityLabel("\(app.name) volume, 0 to 100")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)

        while alert.runModal() == .alertFirstButtonReturn {
            guard let gain = Int(input.stringValue), (0...100).contains(gain) else {
                alert.informativeText = "Enter a whole number from 0 to 100, for example 40."
                continue
            }
            writeControlChange { try ControlOps.setApp(app.bundleID, gain: gain) }
            return
        }
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
        UserDefaults.standard.set(wantsBrightnessGrab, forKey: "grabBrightnessKeys")
        grabBrightnessItem.state = wantsBrightnessGrab ? .on : .off
    }

    /// Register the app for Input Monitoring (adds it to the list + prompts),
    /// then open that settings pane so the user can flip the toggle.
    @objc private func enableInputMonitoring() {
        BrightnessKeyListener.requestAccess()  // the one place that prompts; it also lists us
        brightnessKeys?.start()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when the built-in panel is active: macOS should keep the
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
            // on the main run loop: no race.
            tap.shouldConsume = { [weak self] in
                guard let self else { return false }
                return self.lastStatusRunning && self.lastPipelineOK
            }
            // Brightness is owned solely by the HID listener (BrightnessKeyListener):
            // in the only case Loudini drives brightness (external DDC display, no
            // built-in), macOS never emits the NX brightness event anyway, so routing
            // it here too would just double-nudge on the rare setup where it does fire.
            // Leave shouldConsumeBrightness at its default (false): the NX tap is volume-only.
            if tap.start() {
                keyTap = tap
            } else {
                NSLog("Loudini: event tap creation failed despite Accessibility trust, watchdog will retry")
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
                NSLog("Loudini: key tap lost (trusted=%d, enabled=%d), rebuilding",
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
            self.isCaptureRivalRunning = self.runningRival().map(Conflicts.isCaptureRival) ?? false
            self.refreshPermissionUI()
            self.renderStatusItem()
        }
    }

    private func refreshPermissionUI() {
        let trusted = AXIsProcessTrusted()
        let needsFix = !trusted && wantsKeyGrab
        fixPermissionItem.isHidden = !needsFix
        accessibilityItem.isHidden = !(needsFix && didAttemptAXFix)
        // A grant that stopped working (macOS revoked it, or a rebuild changed the app's
        // identity) reads differently from a never-granted install.
        if UserDefaults.standard.bool(forKey: "wasEverAXTrusted") {
            fixPermissionItem.title = "Repair Volume Keys…"
            fixPermissionItem.toolTip = "The volume keys stopped working. Click to reset the permission. "
                + "Then turn on Loudini again in the list."
        } else {
            fixPermissionItem.title = "Allow Volume Keys…"
            fixPermissionItem.toolTip = "macOS asks for the Accessibility permission. Turn on Loudini in the list."
        }
        grabKeysItem.title = trusted || !wantsKeyGrab
            ? "Use Volume Keys"
            : "Use Volume Keys (needs permission)"
        grabKeysItem.state = wantsKeyGrab ? .on : .off
    }

    @objc private func toggleGrabKeys() {
        wantsKeyGrab.toggle()
        UserDefaults.standard.set(wantsKeyGrab, forKey: "grabVolumeKeys")
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

    // MARK: updates (Sparkle, see Updater.swift)

    @objc private func toggleUpdateCheck() {
        updater.setAutomatic(!updater.isAutomatic)
        updateCheckItem.state = updater.isAutomatic ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    @objc private func installUpdateClicked() {
        updater.install()
    }

    /// Offer the downloaded update in the menu.
    private func showUpdateRow(_ version: String) {
        guard !isQuitting else { return }
        updateItem.title = "Install Update (v\(version)) and Relaunch"
        // Never change the menu's HEIGHT while it is on screen: a row appearing
        // mid-click would shift every row below it, including Quit, under the
        // pointer. menuWillOpen shows it on the next open.
        guard !isMenuOpen else { return }
        updateItem.isHidden = false
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
        didAttemptAXFix = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility",
                           Bundle.main.bundleIdentifier ?? "gg.pim.loudini.menubar"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Bounded: even if tccutil wedges, the timeout fires and the key-tap
            // rebuild below still runs instead of being stranded behind waitUntilExit.
            _ = Self.runBounded(p)
            DispatchQueue.main.async {
                guard let self, !self.isQuitting else { return }
                self.keyTap?.stop()
                self.keyTap = nil
                self.setupKeyTap(promptIfNeeded: true)
            }
        }
    }

    @objc private func toggleLoginItem() {
        guard !isOutsideApplications else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Loudini: could not change login item: %@", error.localizedDescription)
            // Usually the item was switched off in System Settings, which must allow it again.
            SMAppService.openSystemSettingsLoginItems()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
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
        // launchctl blocks on waitUntilExit, so keep it off the main
        // thread (the event-tap callback lives there). The daemon's flock
        // makes any race here harmless: a redundant instance waits its turn.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if Self.isDaemonAlive() { return }
            if hasAgent {
                // The user installed the LaunchAgent: revive it rather than
                // spawning our own: kickstart restarts a loaded job, bootstrap
                // covers "plist present but never loaded".
                if Self.runLaunchctl(["kickstart", "gui/\(getuid())/gg.pim.loudini"]) != 0 {
                    _ = Self.runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
                }
                // A plist pointing at a moved/deleted binary makes both calls
                // useless (or "succeed" into a job that can never run). Probe
                // once after a grace period and fall back to our bundled
                // daemon: the flock arbitrates if the agent comes up too.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    guard !Self.isDaemonAlive() else { return }
                    NSLog("Loudini: LaunchAgent did not produce a daemon, falling back to the bundled one")
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

    /// Run a Process with a wall-clock deadline: terminate it if it outlives the
    /// timeout, so a wedged utility can't strand this background worker thread in
    /// waitUntilExit forever. Output goes to /dev/null (callers use only the exit
    /// status), so an unread pipe can't fill and block either. Returns the exit
    /// status, or nil if it never started or had to be killed.
    private static func runBounded(_ p: Process, timeout: TimeInterval = 5) -> Int32? {
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return runBounded(p) ?? -1
    }

    /// True when a daemon holds daemon.lock, the same liveness test doctor uses. pgrep
    /// would also match a short-lived CLI run. The probe takes a shared lock and drops it
    /// at once, so it only fails while a daemon holds the exclusive one.
    private static func isDaemonAlive() -> Bool {
        let fd = open(configDir.appendingPathComponent("daemon.lock").path, O_RDONLY)
        guard fd >= 0 else { return false }   // no daemon has ever run here
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func spawnDaemon() {
        // The daemon ships inside the bundle, next to our own executable.
        let url = Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("loudini-helper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            NSLog("Loudini: bundled daemon missing at %@, run menubar/build-app.sh", url.path)
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
        p.terminationHandler = { [weak self] proc in
            // The daemon cannot log its own crash, so record it here. Exit 0 is the
            // routine lost-the-lock exit and stays quiet.
            if proc.terminationReason == .uncaughtSignal || proc.terminationStatus != 0 {
                let how = proc.terminationReason == .uncaughtSignal ? "signal" : "exit"
                NSLog("Loudini: daemon pid %d exited (%@ %d)", proc.processIdentifier, how, proc.terminationStatus)
            }
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
        try? ensureConfigDir()
        // Rotate here, before the open: a daemon already holds its log open, so it
        // cannot rotate its own file. One old generation is kept. Copy then truncate,
        // not rename: other daemons (launchd's, a waiting one) keep their O_APPEND
        // handle, and a rename would leave them writing into daemon.log.1.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 1_000_000 {
            let old = configDir.appendingPathComponent("daemon.log.1")
            try? FileManager.default.removeItem(at: old)
            if (try? FileManager.default.copyItem(at: url, to: old)) != nil { truncate(url.path, 0) }
        }
        // O_APPEND so every write atomically lands at EOF. launchd opens this same
        // daemon.log O_APPEND for its agent daemon; a fixed-offset FileHandle
        // (seekToEndOfFile) would let the two clobber each other during a handoff.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            NSLog("Loudini: cannot open daemon.log (%@), daemon output will be lost", String(cString: strerror(errno)))
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
