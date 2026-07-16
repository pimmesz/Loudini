// DDCBrightness.swift — external-monitor brightness over DDC/CI (Apple Silicon).
//
// Talks to every external display's DCPAVServiceProxy via the IOAVService I2C
// interface (private but long-stable — the same path MonitorControl and m1ddc
// use) and writes VCP 0x10 (luminance). No daemon and no files: the monitor
// itself holds the state. All displays move together (per-display control is
// a later refinement). Degrades to isAvailable=false on Intel Macs, if the
// API moves, or when no external DDC display is attached.

import AppKit
import IOKit

final class DDCBrightness {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferFn = @convention(c)
        (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let create: CreateFn?
    private let writeI2C: TransferFn?
    private let readI2C: TransferFn?

    /// One AV service per external display. Only touched on `queue`.
    private var services: [CFTypeRef] = []
    private var maxValue = 100
    /// 0-100, software-tracked after the initial DDC read (reads are flaky on
    /// some monitors; writes are reliable). Only mutated on `queue`.
    private var percentValue = 50

    /// Serialized DDC IO — concurrent I2C transactions corrupt each other.
    private let queue = DispatchQueue(label: "gg.pim.loudini.menubar.ddc", qos: .userInitiated)

    /// Main-thread mirrors for the UI (menu row visibility, slider position).
    private(set) var isAvailable = false
    private(set) var percent = 50

    init() {
        // Load the private symbols at runtime so a missing API means a
        // disabled feature, not a launch failure.
        func load(_ name: String) -> UnsafeMutableRawPointer? {
            for path in ["/System/Library/Frameworks/IOKit.framework/IOKit",
                         "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"] {
                if let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, name) { return sym }
            }
            return nil
        }
        create = load("IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
        writeI2C = load("IOAVServiceWriteI2C").map { unsafeBitCast($0, to: TransferFn.self) }
        readI2C = load("IOAVServiceReadI2C").map { unsafeBitCast($0, to: TransferFn.self) }
        rediscover()
    }

    /// Re-enumerate external displays; call on screen-parameter changes.
    /// `done` (optional) runs on the main queue afterwards.
    func rediscover(done: (() -> Void)? = nil) {
        queue.async {
            self.rediscoverLocked()
            let available = !self.services.isEmpty
            let p = self.percentValue
            DispatchQueue.main.async {
                self.isAvailable = available
                self.percent = p
                done?()
            }
        }
    }

    /// Coalesces slider bursts: only the newest queued `set` actually writes.
    /// Main-thread only (slider/menu actions).
    private var pendingSet: DispatchWorkItem?

    /// percent += delta (clamped 0-100) on every external display.
    func nudge(_ delta: Int, done: @escaping (Int) -> Void) {
        queue.async {
            self.applyLocked(self.percentValue + min(100, max(-100, delta)), done: done)
        }
    }

    /// percent = value (clamped 0-100). Rapid calls (slider drag) coalesce —
    /// DDC writes are slow, so stale intermediate targets are dropped.
    func set(_ value: Int, done: @escaping (Int) -> Void) {
        pendingSet?.cancel()
        let work = DispatchWorkItem { self.applyLocked(value, done: done) }
        pendingSet = work
        queue.async(execute: work)
    }

    /// On `queue` only.
    private func applyLocked(_ newPercent: Int, done: @escaping (Int) -> Void) {
        percentValue = clampGain(newPercent)
        let raw = Int((Double(percentValue) / 100 * Double(maxValue)).rounded())
        for av in services {
            writeLuminance(av, value: raw)
            usleep(20_000)  // some monitors drop back-to-back DDC writes
        }
        let p = percentValue
        DispatchQueue.main.async {
            self.percent = p
            done(p)
        }
    }

    // MARK: DDC/CI over I2C (chip 0x37, register 0x51) — on `queue` only

    private func rediscoverLocked() {
        services = []
        guard let create, writeI2C != nil, readI2C != nil else { return }
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            let location = IORegistryEntryCreateCFProperty(svc, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let av = create(kCFAllocatorDefault, svc)?.takeRetainedValue() else { continue }
            services.append(av)
        }
        // Seed the tracked level from the first display that answers a read.
        for av in services {
            if let (current, max) = readLuminance(av) {
                maxValue = max > 0 ? max : 100
                percentValue = clampGain(Int((Double(current) / Double(maxValue) * 100).rounded()))
                break
            }
        }
        NSLog("Loudini: DDC external displays=%d brightness=%d%% (max=%d)",
              services.count, percentValue, maxValue)
    }

    /// (current, max) for VCP 0x10, or nil when the monitor doesn't answer.
    private func readLuminance(_ av: CFTypeRef) -> (Int, Int)? {
        guard let writeI2C, let readI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
        for _ in 0..<3 {
            let wrote = request.withUnsafeMutableBytes {
                writeI2C(av, 0x37, 0x51, $0.baseAddress!, 4)
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let read = reply.withUnsafeMutableBytes {
                readI2C(av, 0x37, 0x51, $0.baseAddress!, 12)
            }
            if wrote == KERN_SUCCESS, read == KERN_SUCCESS, reply[2] == 0x02, reply[4] == 0x10 {
                return (Int(reply[8]) << 8 | Int(reply[9]),
                        Int(reply[6]) << 8 | Int(reply[7]))
            }
            usleep(50_000)
        }
        return nil
    }

    private func writeLuminance(_ av: CFTypeRef, value: Int) {
        guard let writeI2C else { return }
        let v = UInt16(clamping: value)
        var data: [UInt8] = [0x84, 0x03, 0x10, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        data[5] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4]
        _ = data.withUnsafeMutableBytes { writeI2C(av, 0x37, 0x51, $0.baseAddress!, 6) }
    }
}
