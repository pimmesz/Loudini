// loudini-helper.swift — Loudini system-audio gain daemon (macOS 14.4+ process taps)
//
// Taps output-producing processes and re-renders them to the current default
// output device (or --device <UID>) through an IOProc that multiplies samples
// by a software master gain. Approach A per-app volume (Phase 2): each app with
// an entry in control.json's `apps` map gets its OWN private tap feeding its own
// gain; those are summed with the global tap (which excludes them) BEFORE the
// master multiply. A per-app tap that fails to create falls open — its app just
// rides the global/master path, audio never dropped. Direct paths are muted
// (.mutedWhenTapped).
//
// Control:  ~/.config/loudini/control.json
//           {"gain": <int 0-100>, "muted": <bool>,
//            "apps": {"<bundleID>": {"gain": 0-100, "muted": bool}, ...}}  (apps optional)
//           polled every 100ms; master multiplier = muted ? 0 : gain/100,
//           per-app multiplier applied pre-master (effective = master × app).
// Status:   ~/.config/loudini/status.json    {"gain","muted","running","device","apps"}
//           written atomically at startup, on every change, and on shutdown
//           (running:false). "apps" is the live roster of processes producing
//           audio right now (kAudioProcessPropertyIsRunningOutput) — read-only.
//
// Fail-open: if this process dies for any reason, coreaudiod destroys the tap +
// aggregate (they are private objects owned by this HAL client) and audio
// returns to the normal direct path.
//
// Build:  swiftc -O -parse-as-library -o loudini-helper \
//           loudini-helper.swift ControlFile.swift DDC.swift \
//           -framework CoreAudio -framework AudioToolbox -framework Foundation \
//           -framework AppKit -framework IOKit
// Usage:  loudini-helper [--device <UID>]                          (daemon)
//         loudini-helper up|down [step] | mute | set <0-100> | get (CLI — writes control.json
//                                                                  and exits; never touches
//                                                                  Core Audio)
// Debug:  LOUDINI_METER=1 loudini-helper   (logs per-second in/out RMS)

import Foundation
import CoreAudio
import AudioToolbox
import AppKit   // NSRunningApplication — resolve pid -> localized app name for the roster
import Darwin   // proc_name — name fallback for audio sources without a bundle

// MARK: - logging

private let logTimestamp = ISO8601DateFormatter()

func log(_ msg: String) {
    let line = "[\(logTimestamp.string(from: Date()))] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// MARK: - small HAL helpers

func fourCC(_ st: OSStatus) -> String {
    let u = UInt32(bitPattern: st)
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return "'\(String(bytes: bytes, encoding: .ascii)!)' (\(st))"
    }
    return "\(st)"
}

func gaddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func getIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = gaddr(sel); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == 0, size > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == 0 else { return [] }
    return out
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = gaddr(sel); var cf: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    guard st == 0 else { return nil }
    return cf as String?
}

struct Dev { let id: AudioObjectID; let uid: String; let name: String }

func device(for id: AudioObjectID) -> Dev? {
    guard id != kAudioObjectUnknown, let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
    return Dev(id: id, uid: uid, name: getString(id, kAudioObjectPropertyName) ?? uid)
}

func deviceMatching(uid: String) -> Dev? {
    for id in getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
        if getString(id, kAudioDevicePropertyDeviceUID) == uid { return device(for: id) }
    }
    return nil
}

func defaultOutputDevice() -> Dev? {
    guard let id = getIDs(AudioObjectID(kAudioObjectSystemObject),
                          kAudioHardwarePropertyDefaultOutputDevice).first else { return nil }
    return device(for: id)
}

/// HAL process object for a pid (needed to exclude ourselves from the global tap).
func processObject(forPID pid: pid_t) -> AudioObjectID? {
    var a = gaddr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var qualifier = pid
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafePointer(to: &qualifier) { qp in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                   UInt32(MemoryLayout<pid_t>.size), qp, &size, &obj)
    }
    if st == 0, obj != kAudioObjectUnknown { return obj }
    // Fallback: scan the process object list for our pid.
    for p in getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
        var pa = gaddr(kAudioProcessPropertyPID); var v: pid_t = 0
        var vs = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(p, &pa, 0, nil, &vs, &v) == 0, v == pid { return p }
    }
    return nil
}

// MARK: - status file (the shared control/status contract lives in ControlFile.swift)

/// Serialize the status contract, including the Phase 1 `apps` roster (always
/// present, empty when nothing is playing). Byte-stable via sortedKeys so the
/// publisher can dedup identical states with a plain Data compare.
func statusData(_ c: Control, running: Bool, pipeline: Bool, device: String,
                reason: String, apps: [AppEntry]) -> Data? {
    var obj: [String: Any] = ["gain": c.gain, "muted": c.muted, "running": running,
                              "pipeline": pipeline, "device": device, "pid": Int(getpid())]
    if !reason.isEmpty { obj["reason"] = reason }
    obj["apps"] = apps.map(appEntryJSON)
    return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
}

func writeStatus(_ c: Control, running: Bool, pipeline: Bool, device: String,
                 reason: String, apps: [AppEntry]) {
    guard let data = statusData(c, running: running, pipeline: pipeline,
                                device: device, reason: reason, apps: apps) else { return }
    do { try atomicWrite(data, to: statusURL) }
    catch { log("status write failed: \(error.localizedDescription)") }
}

// MARK: - tap -> aggregate -> gain pipeline

/// One requested per-app tap (approach A): all live process objects for an
/// overridden bundle id, mixed down to a single stereo stream, with the gain
/// to apply to it before the master multiply.
struct AppTapSpec {
    let bundleID: String
    let procs: [AudioObjectID]
    let gain: Float
}

final class Pipeline {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)   // global tap
    private(set) var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    // Per-app taps (approach A). Each overridden app that got its own tap
    // arrives on its own buffer, is scaled by its per-app gain, and is summed
    // with the global tap BEFORE the master multiply. The global tap excludes
    // exactly these apps' processes, so nothing is double-counted; an app whose
    // tap failed to create is left in the global tap (fail-open -> master path).
    private(set) var appTapIDs: [AudioObjectID] = []
    /// bundle ids of the app taps we actually built, in buffer order — lets the
    /// engine map a bundle id to its gain slot for lock-free in-place updates.
    private(set) var bundleIDsInOrder: [String] = []
    /// Per-app gain slots, one per built app tap, read unsynchronized by the IO
    /// thread exactly like `gain`. Preallocated once (upper bound = requested
    /// taps) so the render loop never allocates; freed via freeAppGains().
    private let appGains: UnsafeMutablePointer<Float>
    /// Guards the single free of `appGains`. See freeAppGains().
    private var appGainsFreed = false
    private var appTapCount = 0
    /// Total tap buffers appended to the aggregate input ABL: 1 (global) + built
    /// app taps. The render loop uses it to find where the tap buffers start.
    private var tapBufferCount = 1

    // First-callback ABL shape, captured with plain word stores (the render
    // thread must not allocate, lock, or do IO) and logged later off-thread.
    private var loggedShape = false
    private var shapeInBufs: Int32 = 0, shapeOutBufs: Int32 = 0
    private var shapeTapCh: Int32 = 0, shapeOutCh: Int32 = 0
    private var shapeTapBytes: UInt32 = 0, shapeOutBytes: UInt32 = 0

    /// Effective multiplier, written by the control loop, read by the IO thread
    /// each callback. Word-aligned 32-bit store/load is atomic on arm64; the
    /// render thread never blocks on this.
    var gain: Float

    // Optional per-second metering (LOUDINI_METER=1), guarded by an unfair
    // lock that is only ever briefly held (proven dropout-free in the prototype).
    private let meterEnabled: Bool
    private var meterLock = os_unfair_lock()
    private var sumIn = 0.0, sumOut = 0.0
    private var meterSamples = 0
    private var callbacks: UInt64 = 0

    init(excludeProcs: [AudioObjectID], appTaps: [AppTapSpec],
         outUID: String, gain: Float, meter: Bool) throws {
        self.gain = gain
        self.meterEnabled = meter
        // Upper bound: never more built taps than requested. Cleanup of appGains
        // is NOT left to deinit — Swift does not reliably run deinit for a
        // throwing initializer even after full initialization — so every throw
        // path below calls freeAppGains() explicitly; the flag it checks makes a
        // later deinit call a harmless no-op.
        let gainCapacity = max(1, appTaps.count)
        self.appGains = UnsafeMutablePointer<Float>.allocate(capacity: gainCapacity)
        self.appGains.initialize(repeating: 1, count: gainCapacity)

        // 1. Per-app taps (approach A). Each is a private stereo mixdown of one
        //    bundle's live processes. Fail-open PER TAP: a tap that won't create
        //    is dropped and its app simply stays in the global tap below, riding
        //    the master path — its audio is never lost.
        var appTapUIDs: [String] = []
        var tappedProcs: [AudioObjectID] = []
        for spec in appTaps where !spec.procs.isEmpty {
            let d = CATapDescription(stereoMixdownOfProcesses: spec.procs)
            d.name = "Loudini app tap \(spec.bundleID)"
            d.isPrivate = true
            d.muteBehavior = .mutedWhenTapped
            var t = AudioObjectID(kAudioObjectUnknown)
            let e = AudioHardwareCreateProcessTap(d, &t)
            guard e == 0, t != kAudioObjectUnknown else {
                log("per-app tap for \(spec.bundleID) failed: \(fourCC(e)) — routing it through the master path (fail-open)")
                continue
            }
            let slot = bundleIDsInOrder.count
            appGains[slot] = spec.gain
            bundleIDsInOrder.append(spec.bundleID)
            appTapIDs.append(t)
            appTapUIDs.append(getString(t, kAudioTapPropertyUID) ?? d.uuid.uuidString)
            tappedProcs.append(contentsOf: spec.procs)
        }
        appTapCount = bundleIDsInOrder.count
        tapBufferCount = 1 + appTapCount

        // 2. Global tap + aggregate + IOProc. Fail-open must extend PAST tap
        //    CREATION: a per-app tap can create fine yet still make the aggregate
        //    or the IOProc creation fail (e.g. an unusable tap UID, or too many
        //    sub-streams). Abandoning the whole pipeline there would silence the
        //    global/master path too, so instead we drop EVERY per-app tap to the
        //    master path and retry global-only. Only if that also fails do we
        //    give up (the engine's retry loop then rebuilds, audio meanwhile on
        //    the untouched direct path).
        do {
            try buildOutput(excludeProcs: excludeProcs, tappedProcs: tappedProcs,
                            outUID: outUID, appTapUIDs: appTapUIDs)
        } catch {
            guard !appTapIDs.isEmpty else { freeAppGains(); throw error }
            log("aggregate/IOProc build failed with \(appTapIDs.count) per-app tap(s): "
                + "\(error.localizedDescription) — dropping them to the master path and retrying global-only (fail-open)")
            for t in appTapIDs { AudioHardwareDestroyProcessTap(t) }
            appTapIDs = []
            bundleIDsInOrder = []
            appTapCount = 0
            tapBufferCount = 1
            do {
                // No exclusions now: the dropped apps ride the global/master path.
                try buildOutput(excludeProcs: excludeProcs, tappedProcs: [],
                                outUID: outUID, appTapUIDs: [])
            } catch {
                freeAppGains()
                throw error
            }
        }
    }

    /// Build the global tap, the aggregate device, and the IOProc for the given
    /// per-app tap UIDs (empty = global-only). Cleans up the HAL objects IT
    /// creates on failure; the per-app taps are owned/torn down by the caller.
    private func buildOutput(excludeProcs: [AudioObjectID], tappedProcs: [AudioObjectID],
                             outUID: String, appTapUIDs: [String]) throws {
        // Global stereo mixdown of every output-producing process except us AND
        // the apps we successfully gave their own tap. New processes are covered
        // automatically (and picked up by a rebuild if overridden).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcs + tappedProcs)
        desc.name = "Loudini tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapErr == 0, tap != kAudioObjectUnknown else {
            throw Self.halError(tapErr, "AudioHardwareCreateProcessTap failed")
        }
        tapID = tap
        let tapUID = getString(tapID, kAudioTapPropertyUID) ?? desc.uuid.uuidString

        // Aggregate: real output device as sub-device + all taps. The global tap
        // is listed FIRST, the per-app taps after it in build order, so the tap
        // buffers appear in that same order at the tail of the input ABL. Key
        // literals verified against AudioHardware.h and proven in the prototype.
        let tapList: [[String: Any]] = [["uid": tapUID, "drift": true]]
            + appTapUIDs.map { ["uid": $0, "drift": true] }
        let aggDesc: [String: Any] = [
            "name": "Loudini",
            "uid": UUID().uuidString,
            "private": true,
            "master": outUID,
            "subdevices": [["uid": outUID, "drift": false]],
            "taps": tapList,
            "tapautostart": true,
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard aggErr == 0, agg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw Self.halError(aggErr, "AudioHardwareCreateAggregateDevice failed")
        }
        aggID = agg

        // unowned(unsafe): a weak capture would do refcount/side-table work in
        // every render callback. Safe because destroy() runs
        // AudioDeviceStop + AudioDeviceDestroyIOProcID before this Pipeline can
        // be released, so no callback can outlive self.
        let io: AudioDeviceIOBlock = { [unowned(unsafe) self] _, inInputData, _, outOutputData, _ in
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            let g = self.gain
            let tapCount = self.tapBufferCount

            for ob in outList where ob.mData != nil {
                memset(ob.mData!, 0, Int(ob.mDataByteSize))
            }

            // The aggregate's input ABL = the sub-device's own input streams
            // first (e.g. an interface's mic/line inputs), then the tap streams
            // appended LAST, one buffer per tap, in the aggregate's tap order:
            // global tap, then the per-app taps we built. So the tap buffers are
            // the final `tapCount` buffers; the app taps follow the global one.
            let nIn = inList.count
            guard nIn >= tapCount, outList.count > 0 else { return }
            let base = nIn - tapCount                // index of the global tap buffer
            let ob = outList[0]
            guard let dstRaw = ob.mData else { return }
            let dst = dstRaw.assumingMemoryBound(to: Float32.self)
            let outCh = max(Int(ob.mNumberChannels), 1)
            let outCount = Int(ob.mDataByteSize) / MemoryLayout<Float32>.size

            if !self.loggedShape {
                let gib = inList[base]
                self.shapeInBufs = Int32(nIn)
                self.shapeOutBufs = Int32(outList.count)
                self.shapeTapCh = Int32(gib.mNumberChannels)
                self.shapeTapBytes = gib.mDataByteSize
                self.shapeOutCh = Int32(ob.mNumberChannels)
                self.shapeOutBytes = ob.mDataByteSize
                self.loggedShape = true
            }

            // Sum every tap into the (pre-zeroed) output, each scaled by its own
            // gain times the master g — folding the master multiply into each add
            // keeps it a single pass and allocation/lock-free. Global tap gain is
            // 1.0 (untouched apps); app-tap gain is the per-app slot. sIn meters
            // the global tap only (representative), sOut the mixed result.
            var sIn = 0.0
            var t = 0
            while t < tapCount {
                let coeff = (t == 0 ? Float(1) : self.appGains[t - 1]) * g
                if coeff != 0 {
                    let ib = inList[base + t]
                    if let srcRaw = ib.mData {
                        let src = srcRaw.assumingMemoryBound(to: Float32.self)
                        let inCh = max(Int(ib.mNumberChannels), 1)
                        let inCount = Int(ib.mDataByteSize) / MemoryLayout<Float32>.size
                        if inCh == outCh {
                            let n = min(inCount, outCount)
                            var k = 0
                            while k < n {
                                let v = src[k]
                                dst[k] += v * coeff
                                if self.meterEnabled && t == 0 { sIn += Double(v * v) }
                                k += 1
                            }
                        } else {
                            // Channel counts differ (e.g. stereo tap -> multichannel
                            // device): map channel-for-channel per frame, leave extra
                            // output channels silent.
                            let frames = min(inCount / inCh, outCount / outCh)
                            let ch = min(inCh, outCh)
                            var f = 0
                            while f < frames {
                                var c = 0
                                while c < ch {
                                    let v = src[f * inCh + c]
                                    dst[f * outCh + c] += v * coeff
                                    if self.meterEnabled && t == 0 { sIn += Double(v * v) }
                                    c += 1
                                }
                                f += 1
                            }
                        }
                    }
                }
                t += 1
            }

            if self.meterEnabled {
                var sOut = 0.0
                var k = 0
                while k < outCount { let w = dst[k]; sOut += Double(w * w); k += 1 }
                os_unfair_lock_lock(&self.meterLock)
                self.sumIn += sIn; self.sumOut += sOut
                self.meterSamples += outCount; self.callbacks += 1
                os_unfair_lock_unlock(&self.meterLock)
            }
        }

        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, io)
        guard ioErr == 0, procID != nil else {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
            AudioHardwareDestroyProcessTap(tap)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw Self.halError(ioErr, "AudioDeviceCreateIOProcIDWithBlock failed")
        }
        ioProcID = procID
    }

    private static func halError(_ code: OSStatus, _ what: String) -> NSError {
        NSError(domain: "loudini", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(fourCC(code))"])
    }

    /// Idempotent free for `appGains`, called from the throwing-init cleanup
    /// paths and from deinit. The flag makes a double call a no-op, so it is
    /// correct whether or not Swift runs deinit for a failed initializer.
    private func freeAppGains() {
        if !appGainsFreed { appGains.deallocate(); appGainsFreed = true }
    }

    deinit { freeAppGains() }

    /// Update one built app tap's gain slot. Lock-free: a word-aligned 32-bit
    /// store, read by the IO thread each callback exactly like `gain`.
    func setAppGain(_ slot: Int, _ g: Float) {
        guard slot >= 0, slot < appTapCount else { return }
        appGains[slot] = g
    }

    func start() throws {
        guard let p = ioProcID, !started else { return }
        let st = AudioDeviceStart(aggID, p)
        guard st == 0 else {
            throw NSError(domain: "loudini", code: Int(st),
                          userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed: \(fourCC(st))"])
        }
        started = true
    }

    /// Non-nil once the first IO callback ran; string building happens on the
    /// caller's thread, never the render thread.
    func shapeDescription() -> String? {
        guard loggedShape else { return nil }
        return "in=\(shapeInBufs) buffers (tap=last: \(shapeTapCh)ch/\(shapeTapBytes)B) "
             + "out=\(shapeOutBufs) buffers ([0]=\(shapeOutCh)ch/\(shapeOutBytes)B)"
    }

    /// (rms in, rms out, callbacks) since last call, then resets.
    func drainMeter() -> (Double, Double, UInt64) {
        os_unfair_lock_lock(&meterLock)
        let n = meterSamples
        let out = (n > 0 ? (sumIn / Double(n)).squareRoot() : 0,
                   n > 0 ? (sumOut / Double(n)).squareRoot() : 0,
                   callbacks)
        sumIn = 0; sumOut = 0; meterSamples = 0; callbacks = 0
        os_unfair_lock_unlock(&meterLock)
        return out
    }

    func destroy() {
        if let p = ioProcID {
            if started { AudioDeviceStop(aggID, p); started = false }
            AudioDeviceDestroyIOProcID(aggID, p)
            ioProcID = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        for t in appTapIDs { AudioHardwareDestroyProcessTap(t) }
        appTapIDs = []
    }
}

// MARK: - live "producing audio" roster (Phase 1: read-only, published to status.json)

/// Watches Core Audio's process objects and maintains the short list of apps
/// that are actually rendering output right now — the whole point of the
/// per-app feature is showing *only* what's making sound, not every dormant
/// audio client. The signal is `kAudioProcessPropertyIsRunningOutput`; identity
/// comes from `kAudioProcessPropertyPID` + `kAudioProcessPropertyBundleID`.
///
/// Push-updated, not polled: a listener on the process-object list catches apps
/// appearing/disappearing, and a per-process listener on IsRunningOutput catches
/// start/stop. A short linger window keeps a row for a few seconds after audio
/// stops so a paused track or inter-song gap doesn't make it flicker; a 1 s
/// timer expires the lingering rows. Publishes an [AppEntry] snapshot on change.
///
/// Phase 1 is read-only — per-app gain/muted are always 100/false here; the
/// render path is untouched. Runs entirely on its own serial queue.
final class AppRoster {
    /// Grace window: how long a row survives after IsRunningOutput goes false,
    /// so pauses and gaps between tracks don't drop and re-add it. Tunable.
    private static let lingerWindow: TimeInterval = 5.0

    private final class Entry {
        let bundleID: String
        var name: String
        var pid: pid_t
        var active: Bool
        var lastActive: Date
        init(bundleID: String, name: String, pid: pid_t, active: Bool, lastActive: Date) {
            self.bundleID = bundleID; self.name = name; self.pid = pid
            self.active = active; self.lastActive = lastActive
        }
    }

    private let queue = DispatchQueue(label: "gg.pim.loudini.roster")
    private let excludePIDs: Set<pid_t>
    private let excludeBundleIDs: Set<String>
    private let onChange: ([AppEntry]) -> Void

    /// Keyed by identity: bundle id, or "pid:<pid>" for sources without a bundle.
    private var entries: [String: Entry] = [:]
    private var published: [AppEntry] = []
    private var isStopped = false

    /// Process objects we hold an IsRunningOutput listener on (kept in sync with
    /// the live process list so we add/remove symmetrically).
    private var subscribed: Set<AudioObjectID> = []
    private var listAddr = gaddr(kAudioHardwarePropertyProcessObjectList)
    private var runningAddr = gaddr(kAudioProcessPropertyIsRunningOutput)
    private var listListener: AudioObjectPropertyListenerBlock!
    private var runningListener: AudioObjectPropertyListenerBlock!
    private var lingerTimer: DispatchSourceTimer?

    init(excludePIDs: Set<pid_t>, excludeBundleIDs: Set<String>,
         onChange: @escaping ([AppEntry]) -> Void) {
        self.excludePIDs = excludePIDs
        self.excludeBundleIDs = excludeBundleIDs
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.runningListener = { [weak self] _, _ in
                self?.queue.async { self?.refresh() }
            }
            self.listListener = { [weak self] _, _ in
                self?.queue.async { self?.resubscribeAndRefresh() }
            }
            _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &self.listAddr, self.queue, self.listListener)
            self.resubscribeAndRefresh()

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.pruneExpired() }
            t.resume()
            self.lingerTimer = t
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            lingerTimer?.cancel(); lingerTimer = nil
            if listListener != nil {
                _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                           &listAddr, queue, listListener)
            }
            for obj in subscribed {
                _ = AudioObjectRemovePropertyListenerBlock(obj, &runningAddr, queue, runningListener)
            }
            subscribed.removeAll()
        }
    }

    // MARK: internals (all on `queue`)

    private func procObjects() -> [AudioObjectID] {
        getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private func resubscribeAndRefresh() {
        guard !isStopped else { return }
        let current = Set(procObjects())
        // Keep already-subscribed processes that are still present; only mark a
        // newly-seen process subscribed when its listener registration succeeds,
        // so a failed add is retried on the next resubscribe tick instead of
        // being silently treated as subscribed forever.
        var nowSubscribed = subscribed.intersection(current)
        for obj in current.subtracting(subscribed) {
            if AudioObjectAddPropertyListenerBlock(obj, &runningAddr, queue, runningListener) == noErr {
                nowSubscribed.insert(obj)
            }
        }
        for obj in subscribed.subtracting(current) {
            _ = AudioObjectRemovePropertyListenerBlock(obj, &runningAddr, queue, runningListener)
        }
        subscribed = nowSubscribed
        refresh()
    }

    private func pid(of obj: AudioObjectID) -> pid_t? {
        var a = gaddr(kAudioProcessPropertyPID); var v: pid_t = 0
        var s = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == 0 ? v : nil
    }

    private func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var a = gaddr(kAudioProcessPropertyIsRunningOutput); var v: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == 0 && v != 0
    }

    /// Rebuild the active set from Core Audio, merge into `entries` (keeping
    /// lingering rows), then prune + publish.
    private func refresh() {
        guard !isStopped else { return }
        let now = Date()
        var activeKeys: Set<String> = []
        for obj in procObjects() {
            guard isRunningOutput(obj), let p = pid(of: obj), !excludePIDs.contains(p) else { continue }
            let bundleID = getString(obj, kAudioProcessPropertyBundleID) ?? ""
            if !bundleID.isEmpty, excludeBundleIDs.contains(bundleID) { continue }
            // One bundle can have several audio processes (e.g. Chrome helpers);
            // collapse them to a single row keyed by bundle id.
            let key = bundleID.isEmpty ? "pid:\(p)" : bundleID
            activeKeys.insert(key)
            if let e = entries[key] {
                e.active = true; e.lastActive = now; e.pid = p
                if e.name.isEmpty { e.name = resolveName(pid: p, bundleID: bundleID) }
            } else {
                entries[key] = Entry(bundleID: bundleID,
                                     name: resolveName(pid: p, bundleID: bundleID),
                                     pid: p, active: true, lastActive: now)
            }
        }
        for (key, e) in entries where e.active && !activeKeys.contains(key) {
            // Just went silent — start the linger clock from now.
            e.active = false
            e.lastActive = now
        }
        pruneExpired()
    }

    private func pruneExpired() {
        guard !isStopped else { return }
        let now = Date()
        let expired = entries.filter { !$0.value.active && now.timeIntervalSince($0.value.lastActive) > Self.lingerWindow }
        for key in expired.keys { entries.removeValue(forKey: key) }
        publishIfChanged()
    }

    private func publishIfChanged() {
        // Phase 1: gain/muted are always the defaults (no render-path override yet).
        let snapshot = entries.values
            .map { AppEntry(bundleID: $0.bundleID, name: $0.name, pid: Int($0.pid),
                            gain: 100, muted: false, active: $0.active) }
            .sorted { ($0.name.lowercased(), $0.bundleID) < ($1.name.lowercased(), $1.bundleID) }
        guard snapshot != published else { return }
        published = snapshot
        onChange(snapshot)
    }

    /// pid -> display name: localizedName for GUI apps, else a bundle-id tail or
    /// the executable name, else the pid.
    private func resolveName(pid: pid_t, bundleID: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let n = app.localizedName, !n.isEmpty {
            return n
        }
        if !bundleID.isEmpty {
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return processName(pid: pid) ?? "pid \(pid)"
    }

    private func processName(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
}

// MARK: - engine: pipeline lifecycle + device tracking

final class Engine {
    private let overrideUID: String?
    private let meterEnabled: Bool
    private let queue = DispatchQueue(label: "gg.pim.loudini.engine")
    private var pipeline: Pipeline?
    private var control = Control(gain: 100, muted: false)
    private var currentDevice: Dev?
    /// Set inside shutdown(); late queue work (an in-flight watcher poll's
    /// apply, a straggling listener rebuild) must not resurrect the pipeline
    /// or republish running:true after the final status write.
    private var isShutdown = false
    private var pendingWork: DispatchWorkItem?
    /// Last status.json bytes we wrote, for deduping redundant writes (now that
    /// the payload includes the apps roster, comparing serialized bytes is the
    /// simplest exact equality check).
    private var lastStatusData: Data?
    /// Why the pipeline is down: "" (it's up), "no-device", or the error text.
    private var lastReason = ""
    private var meterTimer: DispatchSourceTimer?
    /// Live "producing audio" roster, maintained by AppRoster and published in
    /// status.json. Read-only in Phase 1 (no render-path effect).
    private var roster: AppRoster?
    private var currentApps: [AppEntry] = []

    /// Signature of the (overridden ∩ live) process-object set the current
    /// pipeline was built for. A change here (app launch/quit, or the override
    /// map gaining/losing a key) requires a rebuild; a pure gain change does not.
    private var currentAppTapSig = ""
    /// bundle id -> gain slot for the app taps the current pipeline actually
    /// built, used for lock-free in-place per-app gain updates.
    private var builtBundleIndex: [String: Int] = [:]

    // Listener blocks are retained so they can be removed symmetrically.
    private var systemListener: AudioObjectPropertyListenerBlock!
    private var deviceListener: AudioObjectPropertyListenerBlock!
    private var deviceListenerTarget = AudioObjectID(kAudioObjectUnknown)
    /// Fires when processes appear/disappear, so a launched/quit overridden app
    /// re-forms its per-app tap. Independent of AppRoster's own list listener.
    private var procListListener: AudioObjectPropertyListenerBlock!

    private var defaultOutAddr = gaddr(kAudioHardwarePropertyDefaultOutputDevice)
    private var rateAddr = gaddr(kAudioDevicePropertyNominalSampleRate)
    private var aliveAddr = gaddr(kAudioDevicePropertyDeviceIsAlive)
    private var procListAddr = gaddr(kAudioHardwarePropertyProcessObjectList)

    init(overrideUID: String?, meter: Bool) {
        self.overrideUID = overrideUID
        self.meterEnabled = meter
    }

    func start(initialControl: Control) {
        queue.sync {
            control = initialControl

            // NOTE: deliberately NO kAudioHardwarePropertyDevices listener — our
            // own aggregate create/destroy fires it, which feedback-loops into
            // endless rebuilds (observed live). Hot-plug of a missing target
            // device is covered by the 2s retry loop instead; removal/rate
            // changes by the per-device listeners below.
            systemListener = { [weak self] _, _ in
                guard let self else { return }
                // Only rebuild if the default output actually moved elsewhere.
                let newUID = defaultOutputDevice()?.uid
                guard newUID != self.currentDevice?.uid else { return }
                self.scheduleRebuild(reason: "default output changed")
            }
            deviceListener = { [weak self] _, _ in
                guard let self else { return }
                self.scheduleRebuild(reason: "output device sample rate / alive changed")
            }
            if overrideUID == nil {
                _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                        &defaultOutAddr, queue, systemListener)
            }

            // Watch the process-object list so an overridden app launching or
            // quitting re-forms (or drops) its per-app tap. Cheap: it only
            // rebuilds when the tapped-process SET actually changes.
            procListListener = { [weak self] _, _ in self?.reconcileAppTaps() }
            _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &procListAddr, queue, procListListener)

            rebuildLocked(reason: "startup")

            // Publish the live "producing audio" roster. Independent of the tap
            // pipeline: it only reads process-object properties, so it works
            // even while the pipeline is down (e.g. permission not yet granted).
            let r = AppRoster(excludePIDs: [getpid()],
                              excludeBundleIDs: ["gg.pim.loudini", "gg.pim.loudini.menubar"]) { [weak self] apps in
                guard let self else { return }
                self.queue.async {
                    guard !self.isShutdown else { return }
                    self.currentApps = apps
                    self.publishStatus()
                }
            }
            r.start()
            roster = r

            if meterEnabled {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 1, repeating: 1)
                t.setEventHandler { [weak self] in
                    guard let self, let p = self.pipeline else { return }
                    let (rIn, rOut, cbs) = p.drainMeter()
                    log(String(format: "meter: cb=%d inRMS=%.5f outRMS=%.5f gain=%.2f", cbs, rIn, rOut, p.gain))
                }
                t.resume()
                meterTimer = t
            }
        }
    }

    /// Called from the control watcher whenever control.json changed.
    func apply(control newControl: Control) {
        queue.async { [self] in
            guard !isShutdown, newControl != control else { return }
            control = newControl
            pipeline?.gain = newControl.multiplier
            // Per-app: rebuild only if the tapped-process SET changed (a bundle
            // gained/lost an override, or its process set changed). A pure gain
            // change reuses the existing taps — a lock-free float store, no HAL
            // churn, no render glitch.
            if pipeline != nil {
                if appTapSig(desiredAppTaps()) != currentAppTapSig {
                    scheduleRebuild(reason: "per-app override set changed")
                } else {
                    for (bid, slot) in builtBundleIndex {
                        pipeline?.setAppGain(slot, control.apps[bid]?.multiplier ?? 1)
                    }
                }
            }
            log("control: gain=\(newControl.gain) muted=\(newControl.muted) apps=\(newControl.apps.count) -> master \(newControl.multiplier)")
            publishStatus()
        }
    }

    /// The per-app taps we WANT right now: each overridden bundle id that has at
    /// least one live process object, paired with those objects (all of them —
    /// one bundle can have several audio processes, e.g. Chrome helpers). Sorted
    /// for a stable signature.
    private func desiredAppTaps() -> [(bundleID: String, procs: [AudioObjectID])] {
        guard !control.apps.isEmpty else { return [] }
        var byBundle: [String: [AudioObjectID]] = [:]
        for obj in getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let bid = getString(obj, kAudioProcessPropertyBundleID), !bid.isEmpty,
                  control.apps[bid] != nil else { continue }
            byBundle[bid, default: []].append(obj)
        }
        return control.apps.keys.sorted().compactMap { bid in
            guard let procs = byBundle[bid], !procs.isEmpty else { return nil }
            return (bundleID: bid, procs: procs.sorted())
        }
    }

    private func appTapSig(_ taps: [(bundleID: String, procs: [AudioObjectID])]) -> String {
        taps.map { "\($0.bundleID)=\($0.procs.map(String.init).joined(separator: ","))" }
            .joined(separator: "|")
    }

    /// Process list changed — rebuild only if that moved the tapped-process set
    /// (an overridden app launched/quit). Pauses and unrelated apps are no-ops.
    private func reconcileAppTaps() {
        guard !isShutdown, pipeline != nil else { return }   // pipeline down -> retry loop rebuilds
        if appTapSig(desiredAppTaps()) != currentAppTapSig {
            scheduleRebuild(reason: "overridden app launched/quit")
        }
    }

    func shutdown() {
        queue.sync {
            isShutdown = true
            pendingWork?.cancel()
            meterTimer?.cancel()
            roster?.stop()
            roster = nil
            currentApps = []
            removeDeviceListeners()
            if overrideUID == nil {
                _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                           &defaultOutAddr, queue, systemListener)
            }
            if procListListener != nil {
                _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                           &procListAddr, queue, procListListener)
            }
            pipeline?.destroy()
            pipeline = nil
            writeStatus(control, running: false, pipeline: false,
                        device: currentDevice?.name ?? "", reason: "", apps: [])
            log("shutdown: tap + aggregate destroyed, direct audio path restored")
        }
    }

    // MARK: internals (all on `queue`)

    private func scheduleRebuild(reason: String, after: TimeInterval = 0.3) {
        guard !isShutdown else { return }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildLocked(reason: reason) }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func rebuildLocked(reason: String) {
        guard !isShutdown else { return }
        removeDeviceListeners()
        pipeline?.destroy()
        pipeline = nil
        // No pipeline ⇒ no per-app tap is applied. Clear the built index now so
        // appsForStatus() reports master-only for every app while we are down or
        // if this rebuild fails; it is repopulated from the new pipeline on success.
        builtBundleIndex = [:]

        let target: Dev?
        if let uid = overrideUID {
            target = deviceMatching(uid: uid)
            if target == nil { log("rebuild(\(reason)): no device with UID '\(uid)' present") }
        } else {
            target = defaultOutputDevice()
            if target == nil { log("rebuild(\(reason)): no default output device") }
        }
        guard let dev = target else {
            currentDevice = nil
            lastReason = "no-device"
            publishStatus()
            scheduleRebuild(reason: "retry", after: 2.0)   // fail-open: audio stays on the direct path
            return
        }

        guard let selfProc = processObject(forPID: getpid()) else {
            log("rebuild(\(reason)): cannot resolve own HAL process object yet, retrying in 2s")
            // The old pipeline is already destroyed — publish that truthfully,
            // or status.json keeps claiming pipeline:true through the retries.
            currentDevice = nil
            lastReason = "cannot resolve own HAL process object"
            publishStatus()
            scheduleRebuild(reason: "retry", after: 2.0)
            return
        }

        let desired = desiredAppTaps()
        let specs = desired.map { AppTapSpec(bundleID: $0.bundleID, procs: $0.procs,
                                             gain: control.apps[$0.bundleID]?.multiplier ?? 1) }

        // Build the pipeline and start its IOProc, cleaning up on any failure.
        // `start()` (AudioDeviceStart) is NOT covered by Pipeline's internal
        // fail-open — only tap/aggregate/IOProc *creation* is. Without a start
        // failure orphaning the live tap+aggregate inside coreaudiod on every
        // retry (the daemon stays alive, so die-time cleanup never happens),
        // destroy explicitly before rethrowing.
        func buildAndStart(_ specs: [AppTapSpec]) throws -> Pipeline {
            let p = try Pipeline(excludeProcs: [selfProc], appTaps: specs, outUID: dev.uid,
                                 gain: control.multiplier, meter: meterEnabled)
            do {
                try p.start()
            } catch {
                p.destroy()
                throw error
            }
            return p
        }

        do {
            let p: Pipeline
            do {
                p = try buildAndStart(specs)
            } catch {
                // A per-app pipeline that built but wouldn't START: fall open to
                // global-only NOW rather than tearing down and retrying the SAME
                // per-app config on the retry loop — otherwise one problematic app
                // tap keeps the entire master pipeline unavailable. This mirrors
                // Pipeline.init's fail-open for the aggregate/IOProc build. If
                // there were no per-app taps to drop, there is nothing to fall
                // open to, so rethrow into the retry loop (audio stays direct).
                guard !specs.isEmpty else { throw error }
                log("per-app pipeline failed to start: \(error.localizedDescription) — "
                    + "dropping all per-app taps to the master path and rebuilding global-only (fail-open)")
                p = try buildAndStart([])
            }
            pipeline = p
            currentDevice = dev
            lastReason = ""
            // Signature reflects what we WANTED (`desired`), not what built, so a
            // per-app tap that failed-open into the master path doesn't make the
            // set look "changed" every poll and thrash rebuilds.
            currentAppTapSig = appTapSig(desired)
            builtBundleIndex = Dictionary(uniqueKeysWithValues:
                p.bundleIDsInOrder.enumerated().map { ($1, $0) })
            addDeviceListeners(dev.id)
            let appNote = p.bundleIDsInOrder.isEmpty
                ? "no per-app taps"
                : "per-app taps: \(p.bundleIDsInOrder.joined(separator: ", "))"
            let dropped = desired.count - p.bundleIDsInOrder.count
            let droppedNote = dropped > 0 ? " (\(dropped) fell open to master path)" : ""
            log("pipeline live (\(reason)): global tap [excl. pid \(getpid())] -> master \(control.multiplier) -> \(dev.name) [\(dev.uid)]; \(appNote)\(droppedNote)")
            scheduleShapeLog(for: p)
            publishStatus()
        } catch {
            log("rebuild(\(reason)) failed: \(error.localizedDescription) — audio untouched (fail-open), retrying in 2s")
            currentDevice = nil
            lastReason = error.localizedDescription
            publishStatus()
            scheduleRebuild(reason: "retry", after: 2.0)
        }
    }

    /// Log the first IO callback's buffer shape once it exists. The render
    /// thread only captures it (plain stores, no IO); we poll from this queue
    /// because silence can mean no tap callbacks for a while.
    private func scheduleShapeLog(for p: Pipeline, attempt: Int = 0) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak p] in
            guard let self, let p, p === self.pipeline else { return }
            if let shape = p.shapeDescription() {
                log("first IO callback: \(shape)")
            } else if attempt < 30 {
                self.scheduleShapeLog(for: p, attempt: attempt + 1)
            }
        }
    }

    private func addDeviceListeners(_ dev: AudioObjectID) {
        deviceListenerTarget = dev
        _ = AudioObjectAddPropertyListenerBlock(dev, &rateAddr, queue, deviceListener)
        _ = AudioObjectAddPropertyListenerBlock(dev, &aliveAddr, queue, deviceListener)
    }

    private func removeDeviceListeners() {
        guard deviceListenerTarget != kAudioObjectUnknown else { return }
        _ = AudioObjectRemovePropertyListenerBlock(deviceListenerTarget, &rateAddr, queue, deviceListener)
        _ = AudioObjectRemovePropertyListenerBlock(deviceListenerTarget, &aliveAddr, queue, deviceListener)
        deviceListenerTarget = AudioObjectID(kAudioObjectUnknown)
    }

    /// The roster to publish: the live "producing audio" list with each entry's
    /// gain/muted overlaid from the active per-app override — but ONLY for apps
    /// whose per-app tap the current pipeline actually BUILT. An app that fell
    /// open to the master path (its tap failed to create, the aggregate/IOProc
    /// build dropped it, or the pipeline is down) receives master-only gain, so
    /// status.json must report the default 100/false for it, not the requested
    /// override. builtBundleIndex is the authoritative set of applied taps.
    private func appsForStatus() -> [AppEntry] {
        guard !builtBundleIndex.isEmpty else { return currentApps }
        return currentApps.map { entry in
            guard builtBundleIndex[entry.bundleID] != nil,
                  let o = control.apps[entry.bundleID] else { return entry }
            var e = entry
            e.gain = o.gain
            e.muted = o.muted
            return e
        }
    }

    private func publishStatus() {
        guard let data = statusData(control, running: true, pipeline: pipeline != nil,
                                    device: currentDevice?.name ?? "", reason: lastReason,
                                    apps: appsForStatus()) else { return }
        if lastStatusData == data { return }
        // Only mark this state as published once the write actually lands — a
        // transient write failure must not suppress the retry on the next tick.
        do {
            try atomicWrite(data, to: statusURL)
            lastStatusData = data
        } catch { log("status write failed: \(error.localizedDescription)") }
    }
}

// MARK: - control file watcher (100ms poll)

final class ControlWatcher {
    private let queue = DispatchQueue(label: "gg.pim.loudini.control")
    private var timer: DispatchSourceTimer?
    private var lastSignature: String = ""
    private var lastGood: Control
    private var warnedBadFile = false
    private let onChange: (Control) -> Void

    init(initial: Control, onChange: @escaping (Control) -> Void) {
        self.lastGood = initial
        self.onChange = onChange
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: controlURL.path) else { return }
        let sig = "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attrs[.size] as? Int ?? 0)"
        guard sig != lastSignature else { return }
        lastSignature = sig

        guard let c = readControl(previous: lastGood) else {
            if !warnedBadFile {
                warnedBadFile = true
                log("control.json unreadable/malformed — keeping gain=\(lastGood.gain) muted=\(lastGood.muted)")
            }
            return
        }
        warnedBadFile = false
        guard c != lastGood else { return }
        lastGood = c
        onChange(c)
    }
}

// MARK: - main

let usageText = """
usage: loudini-helper [--device <UID>]   run the gain daemon (default: current output device)
       loudini-helper up [step]          gain += step (default 6), un-mute
       loudini-helper down [step]        gain -= step (default 6), un-mute
       loudini-helper mute               toggle mute
       loudini-helper set <0-100>        set gain
       loudini-helper get                print current level (status.json if present)
       loudini-helper apps               list apps currently producing audio (from status.json)
       loudini-helper apps reset         reset every per-app volume to 100% (clears overrides)
       loudini-helper app <id|name> set <0-100> | mute | get
                                         set/toggle/read one app's volume (bundle id exact, name fuzzy)
       loudini-helper doctor             diagnose the whole setup, with fixes
       loudini-helper brightness up|down [step] | set <0-100> | get
                                         external-monitor brightness over DDC (no permission needed)
"""

func usage() -> Never {
    print(usageText)
    exit(64)
}

@main
enum LoudiniHelper {
    // Static so they live for the whole daemon run: Swift may release locals
    // after their last use even though dispatchMain() never returns, which
    // would cancel the dispatch sources.
    private static var engine: Engine!
    private static var watcher: ControlWatcher!
    private static var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "up", "down", "mute", "set", "get", "apps", "app":
            runCLI(args)
        case "doctor":
            runDoctor()
        case "brightness":
            runBrightness(Array(args.dropFirst()))
        default:
            runDaemon(args)
        }
    }

    // MARK: CLI subcommands — read/modify/atomic-write control.json, then exit.
    // They never touch Core Audio; the running daemon applies the change on
    // its next 100 ms poll.

    /// Resolve a user-typed `app` target to a bundle id. Bundle id is exact
    /// (and usable even when the app isn't in the roster — you can pre-set a
    /// silent app); a name is matched case-insensitively over the live roster
    /// (exact name, then substring, then bundle-id substring). Falls back to
    /// treating a dotted token as a bundle id so a not-yet-playing app is still
    /// addressable. nil when nothing plausibly matches. Roster hits with an
    /// empty bundle id (bundle-less sources like raw CLI/helper audio) are
    /// skipped — there's no stable key to write, so set/mute would silently
    /// no-op on "".
    private static func resolveAppTarget(_ token: String, _ roster: [AppEntry]) -> String? {
        if !token.isEmpty, roster.contains(where: { $0.bundleID == token }) { return token }
        let lower = token.lowercased()
        if let hit = roster.first(where: { $0.name.lowercased() == lower && !$0.bundleID.isEmpty }) {
            return hit.bundleID
        }
        if let hit = roster.first(where: { !$0.bundleID.isEmpty && $0.bundleID.lowercased() == lower }) {
            return hit.bundleID
        }
        if let hit = roster.first(where: { $0.name.lowercased().contains(lower) }),
           !hit.bundleID.isEmpty { return hit.bundleID }
        return token.contains(".") ? token : nil
    }

    private static func runCLI(_ args: [String]) -> Never {
        do {
            switch args[0] {
            case "up", "down":
                guard args.count <= 2 else { usage() }
                var step = 6
                if args.count == 2 {
                    // 0-100 only: gain saturates there anyway, and a sane range
                    // means the negation below can never overflow.
                    guard let s = Int(args[1]), (0...100).contains(s) else { usage() }
                    step = s
                }
                try ControlOps.nudge(args[0] == "up" ? step : -step)
            case "mute":
                guard args.count == 1 else { usage() }
                try ControlOps.toggleMute()
            case "set":
                guard args.count == 2, let g = Int(args[1]) else { usage() }
                try ControlOps.set(gain: g)
            case "get":
                guard args.count == 1 else { usage() }
                if let s = readStatus() {
                    print("gain=\(s.gain) muted=\(s.muted) running=\(s.running) "
                        + "pipeline=\(s.pipeline) device=\"\(s.device)\"")
                } else {
                    let c = ControlOps.current()
                    print("gain=\(c.gain) muted=\(c.muted) running=false pipeline=false device=\"\"")
                }
            case "apps":
                // `apps reset` clears every override; bare `apps` is a read-only
                // dump of the daemon's roster (status.json). Never touches Core Audio.
                if args.count == 2, args[1] == "reset" {
                    try ControlOps.resetApps()
                    print("reset all per-app volumes to 100%")
                    break
                }
                guard args.count == 1 else { usage() }
                let apps = readStatus()?.apps ?? []
                if apps.isEmpty {
                    print("No apps are producing audio.")
                } else {
                    for a in apps {
                        let id = a.bundleID.isEmpty ? "-" : a.bundleID
                        let idle = a.active ? "" : "  (idle)"
                        print("\(id)\t\(a.name)\tgain=\(a.gain)\tmuted=\(a.muted)\(idle)")
                    }
                }
            case "app":
                // app <bundleID|name> set <0-100> | mute | get. Bundle id is exact
                // (settable even while the app is silent); name is a fuzzy,
                // case-insensitive convenience over the live roster.
                guard args.count >= 3 else { usage() }
                let roster = readStatus()?.apps ?? []
                guard let bid = resolveAppTarget(args[1], roster) else {
                    FileHandle.standardError.write(
                        Data("error: no app matches \"\(args[1])\" — try `loudini apps`\n".utf8))
                    exit(1)
                }
                switch args[2] {
                case "set":
                    guard args.count == 4, let g = Int(args[3]), (0...100).contains(g) else { usage() }
                    try ControlOps.setApp(bid, gain: g)
                    print("\(bid) gain=\(g)")
                case "mute":
                    guard args.count == 3 else { usage() }
                    let c = try ControlOps.toggleAppMute(bid)
                    print("\(bid) muted=\(c.apps[bid]?.muted ?? false)")
                case "get":
                    guard args.count == 3 else { usage() }
                    // Prefer the daemon's applied values (what's actually audible);
                    // fall back to the pending override in control.json, then default.
                    let applied = roster.first { $0.bundleID == bid }
                    let pending = ControlOps.current().apps[bid]
                    let gain = applied?.gain ?? pending?.gain ?? 100
                    let muted = applied?.muted ?? pending?.muted ?? false
                    print("bundleID=\(bid) gain=\(gain) muted=\(muted)")
                default:
                    usage()
                }
            default:
                usage()
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("error: cannot write \(controlURL.path): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: brightness — external-monitor DDC control (no permission needed).

    private static func runBrightness(_ args: [String]) -> Never {
        guard DDC.isSupported else {
            FileHandle.standardError.write(Data("brightness: DDC not available on this Mac\n".utf8))
            exit(1)
        }
        func step(_ rest: [String]) -> Int {
            guard let s = rest.first else { return 6 }
            guard let n = Int(s), (0...100).contains(n) else { usage() }
            return n
        }
        let applied: Int?
        switch args.first {
        case "up":   applied = DDC.nudge(step(Array(args.dropFirst())))
        case "down": applied = DDC.nudge(-step(Array(args.dropFirst())))
        case "set":
            guard args.count == 2, let n = Int(args[1]) else { usage() }
            applied = DDC.set(percent: n)
        case "get":
            print("brightness=\(DDC.current())")
            exit(0)
        default:
            usage()
        }
        guard let applied else {
            FileHandle.standardError.write(Data("brightness: no external DDC display connected\n".utf8))
            exit(1)
        }
        print("brightness=\(applied)")
        exit(0)
    }

    // MARK: doctor — diagnose the whole setup and print concrete fixes.

    private static func runDoctor() -> Never {
        var failures = 0
        func pass(_ msg: String) { print("  ok   \(msg)") }
        func note(_ msg: String) { print("  --   \(msg)") }
        func warn(_ msg: String, fix: String? = nil) {
            print("  WARN \(msg)")
            if let fix { print("       fix: \(fix)") }
        }
        func fail(_ msg: String, fix: String? = nil) {
            failures += 1
            print("  FAIL \(msg)")
            if let fix { print("       fix: \(fix)") }
        }
        func processRunning(_ name: String) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-x", name]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }

        print("Loudini doctor")

        print("config:")
        let probe = configDir.appendingPathComponent(".loudini-doctor-probe")
        do {
            try atomicWrite(Data("ok".utf8), to: probe)
            try? FileManager.default.removeItem(at: probe)
            pass("\(configDir.path) writable (atomic write works)")
        } catch {
            fail("cannot write \(configDir.path): \(error.localizedDescription)")
        }
        if !FileManager.default.fileExists(atPath: controlURL.path) {
            note("control.json missing (first run — created when the daemon starts or on `loudini set`)")
        } else if let data = try? Data(contentsOf: controlURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Per-key check matching the daemon's lenient parser exactly: it
            // silently keeps its last-good value for a missing/mistyped key.
            let gain = (obj["gain"] as? NSNumber).map { clampGain($0.intValue) }
            let muted = obj["muted"] as? Bool
            if let gain, let muted {
                pass("control.json valid: gain=\(gain) muted=\(muted)")
            } else {
                var bad: [String] = []
                if gain == nil { bad.append("gain") }
                if muted == nil { bad.append("muted") }
                warn("control.json parses, but \(bad.joined(separator: " and ")) missing/mistyped — "
                    + "the daemon keeps its last-good value for those",
                     fix: "loudini set 50   # rewrites the file atomically with both keys")
            }
        } else {
            fail("control.json unreadable or not valid JSON (daemon keeps last good values)",
                 fix: "loudini set 50   # rewrites it atomically")
        }

        print("daemon:")
        // The daemon holds an exclusive flock on daemon.lock for its lifetime;
        // probing the lock is the authoritative liveness check (survives pgrep
        // false positives and stale status files).
        var daemonAlive = false
        let lockFD = open(configDir.appendingPathComponent("daemon.lock").path, O_RDWR)
        if lockFD >= 0 {
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                flock(lockFD, LOCK_UN)
            } else {
                daemonAlive = true
            }
            close(lockFD)
        }
        if daemonAlive {
            pass("daemon running (daemon.lock is held)")
        } else {
            fail("no daemon running — volume changes do nothing",
                 fix: "open the Loudini menu-bar app, or scripts/install-daemon.sh")
        }
        if let s = readStatus() {
            if daemonAlive {
                if !s.running {
                    warn("daemon.lock held but status.json says running=false — daemon may be mid-start; re-run doctor")
                } else if s.pipeline {
                    pass("audio pipeline live on \"\(s.device)\" (gain=\(s.gain) muted=\(s.muted))")
                } else if s.reason == "no-device" {
                    fail("daemon running but no output device is available",
                         fix: "connect or select an output device (System Settings -> Sound)")
                } else {
                    let detail = s.reason.isEmpty ? "" : " (daemon reports: \(s.reason))"
                    fail("daemon running but NO audio pipeline — likely missing System Audio Recording permission\(detail)",
                         fix: "System Settings -> Privacy & Security -> Screen & System Audio Recording: "
                            + "enable the app that runs the daemon; details in ~/.config/loudini/daemon.log")
                }
            } else if s.running {
                warn("stale status.json (claims running, but no daemon holds the lock — a daemon was killed hard)")
            }
        } else if daemonAlive {
            warn("daemon running but status.json missing/unreadable — re-run doctor in a few seconds")
        }

        print("launchd:")
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/gg.pim.loudini.plist"
        if FileManager.default.fileExists(atPath: plistPath) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["print", "gui/\(getuid())/gg.pim.loudini"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                pass("LaunchAgent installed and loaded")
            } else {
                warn("LaunchAgent plist installed but not loaded",
                     fix: "launchctl bootstrap gui/$(id -u) \(plistPath)")
            }
        } else {
            note("no LaunchAgent (fine when the menu-bar app runs the daemon)")
        }

        print("environment:")
        if processRunning("Background Music") {
            fail("Background Music is running — it double-captures with Loudini and feeds back",
                 fix: "quit/uninstall Background Music; Loudini replaces it")
        } else {
            pass("Background Music not running")
        }
        for rival in ["MonitorControl", "BeardedSpice"] where processRunning(rival) {
            warn("\(rival) is running and may intercept the volume keys",
                 fix: "disable volume-key handling in \(rival), or launch the Loudini app after it")
        }

        print(failures == 0 ? "\nAll good." : "\n\(failures) problem(s) found.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: daemon mode (behavior unchanged)

    private static func runDaemon(_ args: [String]) {
        var overrideUID: String? = nil
        var argIter = args.makeIterator()
        while let arg = argIter.next() {
            switch arg {
            case "--device":
                guard let v = argIter.next(), !v.isEmpty else { usage() }
                overrideUID = v
            case "-h", "--help":
                print(usageText)
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
                usage()
            }
        }

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            log("FATAL: cannot create \(configDir.path): \(error.localizedDescription)")
            exit(1)
        }

        // Single-instance guard: two daemons would tap each other and double-
        // apply gain. The kernel drops the flock on ANY death, so this can
        // never wedge (fail-open extends to the lock itself).
        let lockFD = open(configDir.appendingPathComponent("daemon.lock").path,
                          O_CREAT | O_RDWR, 0o644)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            log("another loudini-helper daemon is already running — exiting (single-instance)")
            exit(0)
        }

        sweepStaleTempFiles()
        if !FileManager.default.fileExists(atPath: controlURL.path) {
            do {
                try writeControl(Control(gain: 100, muted: false))
                log("created default \(controlURL.path)")
            } catch {
                log("cannot create default \(controlURL.path): \(error.localizedDescription)")
            }
        }

        let initialControl = ControlOps.current()
        let meterEnabled = ProcessInfo.processInfo.environment["LOUDINI_METER"] == "1"

        engine = Engine(overrideUID: overrideUID, meter: meterEnabled)
        engine.start(initialControl: initialControl)

        watcher = ControlWatcher(initial: initialControl) { engine.apply(control: $0) }
        watcher.start()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                watcher.stop()
                engine.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }

        log("loudini-helper started (pid \(getpid()))\(overrideUID.map { " device override \($0)" } ?? "")")
        dispatchMain()
    }

    /// Remove atomic-write temp files orphaned by writers that were killed
    /// between write and rename. Only OUR naming pattern, and only files older
    /// than a minute — younger ones may belong to a write still in flight.
    private static func sweepStaleTempFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: configDir.path) else { return }
        for name in names
        where (name.hasPrefix(".control.json.") || name.hasPrefix(".status.json."))
            && name.hasSuffix(".tmp") {
            let url = configDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(mtime) > 60 else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
