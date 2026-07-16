// VolumeKeyTap.swift — grabs the hardware volume keys with a session CGEventTap.
//
// Media keys arrive as NX_SYSDEFINED (CGEventType 14) system events. We consume
// volume up/down/mute (return nil from the callback) so macOS never shows its
// crossed-out "no volume" HUD, and forward presses to a handler. Requires
// Accessibility trust (AXIsProcessTrusted) or tap creation fails.

import AppKit

// From <IOKit/hidsystem/ev_keymap.h> — not exposed to Swift.
private let NX_KEYTYPE_SOUND_UP: Int64 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int64 = 1
private let NX_KEYTYPE_BRIGHTNESS_UP: Int64 = 2
private let NX_KEYTYPE_BRIGHTNESS_DOWN: Int64 = 3
private let NX_KEYTYPE_MUTE: Int64 = 7
private let NX_SYSDEFINED: UInt32 = 14
private let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8

final class VolumeKeyTap {
    enum Key { case up, down, mute, brightnessUp, brightnessDown }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: (Key) -> Void

    /// Consulted per event, on the main run loop. When false, volume keys pass
    /// through to macOS untouched — Loudini only owns them while its daemon is
    /// actually controlling audio.
    var shouldConsume: () -> Bool = { true }

    /// Same idea for the brightness keys: only own them when an external DDC
    /// display exists and macOS isn't managing a built-in panel.
    var shouldConsumeBrightness: () -> Bool = { false }

    /// `handler` is called on the main run loop (where the tap lives); it must
    /// not block — hand real work to another queue.
    init(handler: @escaping (Key) -> Void) {
        self.handler = handler
    }

    deinit {
        // The callback holds `self` unretained — never let a live tap outlive us.
        stop()
    }

    var isRunning: Bool { tap != nil }

    /// False when the tap is missing OR macOS has disabled it behind our back.
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Returns false when the tap can't be created (no Accessibility trust).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            let me = Unmanaged<VolumeKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, cgEvent: cgEvent)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED),
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap it thinks is stalling; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard type.rawValue == NX_SYSDEFINED,
              let ev = NSEvent(cgEvent: cgEvent),
              ev.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS
        else { return Unmanaged.passUnretained(cgEvent) }

        // data1 layout: high 16 bits = key code, low 16 = flags;
        // flags bits 8-15 = 0x0A on key-down (repeats included), 0x0B on key-up.
        let data1 = Int64(ev.data1)
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let isKeyDown = ((data1 & 0xFF00) >> 8) == 0x0A

        let key: Key
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP: key = .up
        case NX_KEYTYPE_SOUND_DOWN: key = .down
        case NX_KEYTYPE_MUTE: key = .mute
        case NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
        case NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
        default: return Unmanaged.passUnretained(cgEvent)
        }

        let isBrightness = key == .brightnessUp || key == .brightnessDown
        let willConsume = isBrightness ? shouldConsumeBrightness() : shouldConsume()
        guard willConsume else {
            return Unmanaged.passUnretained(cgEvent)
        }
        if isKeyDown { handler(key) }
        return nil  // consume down AND up so macOS never reacts to the key
    }
}
