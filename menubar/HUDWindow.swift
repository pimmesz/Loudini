// HUDWindow.swift — transient on-screen volume overlay, in the spirit of the
// native macOS HUD we suppress: borderless, click-through, never steals focus,
// fades out ~1 s after the last change. Driven off status.json changes, so it
// reacts to EVERY frontend (keys, CLI, Stream Deck, slider).

import AppKit

/// Menu-bar / HUD glyph for a gain level (muted is handled by the caller).
func speakerSymbolName(for gain: Int) -> String {
    switch gain {
    case 0: return "speaker.fill"
    case 1...33: return "speaker.wave.1.fill"
    case 34...66: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

final class HUDWindow {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 64))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        panel.contentView = effect

        icon.frame = NSRect(x: 16, y: 20, width: 30, height: 24)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        effect.addSubview(icon)

        label.frame = NSRect(x: 56, y: 34, width: 168, height: 18)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        effect.addSubview(label)

        bar.frame = NSRect(x: 58, y: 16, width: 164, height: 8)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        effect.addSubview(bar)
    }

    /// Show (or refresh) the HUD; it fades out ~1 s after the last call.
    func show(gain: Int, muted: Bool) {
        show(symbol: muted ? "speaker.slash.fill" : speakerSymbolName(for: gain),
             text: muted ? "Muted" : "Volume \(gain)%",
             value: gain, dimmedBar: muted)
    }

    /// Brightness variant — same panel, sun icon.
    func show(brightnessPercent: Int) {
        show(symbol: brightnessPercent <= 33 ? "sun.min.fill" : "sun.max.fill",
             text: "Brightness \(brightnessPercent)%",
             value: brightnessPercent, dimmedBar: false)
    }

    private func show(symbol: String, text: String, value: Int, dimmedBar: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        label.stringValue = text
        bar.doubleValue = Double(value)
        bar.alphaValue = dimmedBar ? 0.4 : 1

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 120))
        }
        // Retarget any in-flight fade back to fully visible, instantly.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        })
    }
}
