// BrightnessKeyListener.swift — HID-level brightness keys.
//
// macOS only turns the brightness keys into NX media-key events when it has a
// display whose brightness it can drive itself. With the lid closed on an
// external DDC monitor it has none, so it drops them and no event tap can ever
// see them. This listener reads the keyboard's raw HID reports instead, which
// arrive regardless.
//
// Apple keyboards do not report brightness as such: F1/F2 come in as plain
// keyboard usages (0x07/0x3A, 0x3B) and macOS remaps them host-side. Other
// keyboards emit real Consumer brightness usages. We handle both. Listening
// (not consuming) is fine: on these setups nothing else reacts to the keys.
// Needs the Input Monitoring permission; macOS prompts on first start().

import Foundation
import IOKit.hid

final class BrightnessKeyListener {
    private var manager: IOHIDManager?
    private let onKey: (_ up: Bool) -> Void
    /// Apple keyboards report Fn as its own bit, separate from the key itself.
    private var isFnHeld = false

    /// `onKey` is called on the main run loop for every brightness press (true = up).
    init(onKey: @escaping (_ up: Bool) -> Void) {
        self.onKey = onKey
    }

    /// Whether Input Monitoring is granted (drives the menu affordance).
    static var accessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the Input Monitoring prompt and registers the app in the list.
    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    var isRunning: Bool { manager != nil }

    /// Safe to call repeatedly: it's a no-op once open, and retries while the
    /// Input Monitoring permission is still missing.
    func start() {
        guard manager == nil else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)  // Input Monitoring prompt
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Keyboards only. Matching every device tries to open the mic, Stream
        // Deck, etc. — some are held exclusively by other apps, which fails the
        // whole open. The brightness keys are on a keyboard regardless.
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDDeviceUsagePageKey: 0x01,  // Generic Desktop
            kIOHIDDeviceUsageKey: 0x06,      // Keyboard
        ] as CFDictionary)
        // Keyboard page (Apple F1/F2), Consumer page (other keyboards' real
        // brightness usages), and Apple's two vendor pages for the Fn bit:
        // TopCase (0xFF) on older keyboards, AppleVendorKeyboard (0xFF01) on
        // 2021+ Globe-key keyboards.
        IOHIDManagerSetInputValueMatchingMultiple(m, [
            [kIOHIDElementUsagePageKey: 0x07],
            [kIOHIDElementUsagePageKey: 0x0C],
            [kIOHIDElementUsagePageKey: 0xFF],
            [kIOHIDElementUsagePageKey: 0xFF01],
        ] as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<BrightnessKeyListener>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, ctx)
        // commonModes, not defaultMode: defaultMode stops delivering while a
        // menu is open.
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // Without Input Monitoring the open fails. Drop the manager rather than
        // storing a dead one, or the guard above would block every later retry.
        // Exclusive-access means some other keyboard-like device is held by
        // another app; the ones that did open still deliver, so keep going.
        let opened = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess || opened == kIOReturnExclusiveAccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
            NSLog("Loudini: HID listener open failed (0x%x, Input Monitoring granted=%d) — watchdog will retry",
                  UInt32(bitPattern: opened), Self.accessGranted ? 1 : 0)
            return
        }
        manager = m
    }

    func stop() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    deinit { stop() }

    /// F1/F2 mean brightness only when Fn matches macOS's own rule: with "use
    /// F1, F2 as standard function keys" off (the default), bare F1 is
    /// brightness and Fn+F1 is a real F1. With it on, it's the other way round.
    private var isBrightnessIntent: Bool {
        isFnHeld == UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let isPressed = IOHIDValueGetIntegerValue(value) == 1

        if usage == 0x03, page == 0xFF || page == 0xFF01 {  // Apple Fn key (TopCase / Globe)
            isFnHeld = isPressed
            return
        }
        guard isPressed else { return }  // press only, not release

        switch (page, usage) {
        case (0x07, 0x3A): if isBrightnessIntent { onKey(false) }  // F1 — down
        case (0x07, 0x3B): if isBrightnessIntent { onKey(true) }   // F2 — up
        case (0x0C, 0x70): onKey(false)  // Display Brightness Decrement
        case (0x0C, 0x6F): onKey(true)   // Display Brightness Increment
        default: break
        }
    }
}
