// DDC.swift — external-monitor brightness over DDC/CI (Apple Silicon), for the
// CLI. Pure IOKit + Foundation (no AppKit), so it links into loudini-helper.
//
// DDC writes need NO permission (unlike key capture), which is the whole point:
// bind your brightness keys to `loudini brightness up/down` from any hotkey tool
// and it just works. Talks to every external DCPAVServiceProxy via IOAVService,
// writing VCP 0x10 (luminance). All external displays move together.

import Foundation
import IOKit

enum DDC {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferFn = @convention(c)
        (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static func sym(_ name: String) -> UnsafeMutableRawPointer? {
        for path in ["/System/Library/Frameworks/IOKit.framework/IOKit",
                     "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"] {
            if let handle = dlopen(path, RTLD_NOW), let s = dlsym(handle, name) { return s }
        }
        return nil
    }
    private static let create = sym("IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let writeI2C = sym("IOAVServiceWriteI2C").map { unsafeBitCast($0, to: TransferFn.self) }
    private static let readI2C = sym("IOAVServiceReadI2C").map { unsafeBitCast($0, to: TransferFn.self) }

    /// Last percent we set, so relative up/down survive a monitor that won't
    /// answer DDC reads. Same ~/.config/loudini home as the audio contract.
    private static let cacheURL = configDir.appendingPathComponent("brightness.json")

    static var isSupported: Bool { create != nil && writeI2C != nil }

    /// All external displays' AV services (empty on Intel / no external / no API).
    private static func services() -> [CFTypeRef] {
        guard let create else { return [] }
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [CFTypeRef] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            let location = IORegistryEntryCreateCFProperty(svc, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let av = create(kCFAllocatorDefault, svc)?.takeRetainedValue() else { continue }
            out.append(av)
        }
        return out
    }

    /// Hold an exclusive cross-process lock for a brightness read-modify-write,
    /// so overlapping `loudini brightness` invocations (a held/autorepeated key —
    /// the marketed hotkey path) don't collapse steps or drive concurrent I2C to
    /// the same chip. Fail-open: proceed unlocked if the lock can't be taken.
    private static func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let fd = open(configDir.appendingPathComponent("brightness.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }   // closing releases the flock; the kernel also drops it on exit
        flock(fd, LOCK_EX)
        return body()
    }

    /// Cached last-set percent, or nil if none yet.
    private static func cachedPercent() -> Int? {
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = obj["percent"] as? NSNumber else { return nil }
        return clampGain(n.intValue)
    }

    /// Current brightness 0-100: the monitor's own value if it answers a read,
    /// else the cached last-set value, else 50.
    static func current() -> Int { withLock { currentUnlocked() } }
    private static func currentUnlocked() -> Int {
        if let av = services().first, let (cur, max) = readLuminance(av), max > 0 {
            return clampGain(Int((Double(cur) / Double(max) * 100).rounded()))
        }
        return cachedPercent() ?? 50
    }

    /// Set 0-100 on every external display. Returns the applied value, or nil
    /// when there is nothing to control.
    @discardableResult
    static func set(percent: Int) -> Int? { withLock { applyUnlocked(percent) } }
    @discardableResult
    private static func applyUnlocked(_ percent: Int) -> Int? {
        let svcs = services()
        guard !svcs.isEmpty else { return nil }
        let pct = clampGain(percent)
        // 0-100 maps onto the monitor's own 0..max (usually 100).
        for av in svcs {
            var max = readLuminance(av)?.1 ?? 100
            if max <= 0 { max = 100 }  // a monitor replying max=0 would pin brightness to 0
            writeLuminance(av, value: Int((Double(pct) / 100 * Double(max)).rounded()))
            usleep(20_000)
        }
        // The daemon creates this dir on startup, but the CLI can run first on
        // a fresh machine — without it the cache write silently fails.
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["percent": pct], options: [.sortedKeys])
            .write(to: cacheURL, options: .atomic)
        return pct
    }

    @discardableResult
    static func nudge(_ delta: Int) -> Int? {
        // Whole read-modify-write under one lock. Base the step on the cached
        // last-set value (consistent under a held key), reading the monitor only
        // when there's no cache yet — otherwise the latency-bound read lets
        // overlapping presses collapse into one step.
        withLock { applyUnlocked((cachedPercent() ?? currentUnlocked()) + delta) }
    }

    // MARK: DDC/CI over I2C (chip 0x37, register 0x51)

    private static func readLuminance(_ av: CFTypeRef) -> (Int, Int)? {
        guard let writeI2C, let readI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
        for _ in 0..<3 {
            let wrote = request.withUnsafeMutableBytes { writeI2C(av, 0x37, 0x51, $0.baseAddress!, 4) }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let read = reply.withUnsafeMutableBytes { readI2C(av, 0x37, 0x51, $0.baseAddress!, 12) }
            if wrote == KERN_SUCCESS, read == KERN_SUCCESS, reply[2] == 0x02, reply[4] == 0x10 {
                return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
            }
            usleep(50_000)
        }
        return nil
    }

    private static func writeLuminance(_ av: CFTypeRef, value: Int) {
        guard let writeI2C else { return }
        let v = UInt16(clamping: value)
        var data: [UInt8] = [0x84, 0x03, 0x10, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        data[5] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4]
        _ = data.withUnsafeMutableBytes { writeI2C(av, 0x37, 0x51, $0.baseAddress!, 6) }
    }
}
