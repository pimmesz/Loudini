// ControlFile.swift — the Loudini control-file contract, shared by every Swift frontend
// (the loudini-helper daemon/CLI and the menu-bar app; plugin/src/control.ts mirrors it in TS).
//
// control.json — {"gain": <int 0-100>, "muted": <bool>}. Any frontend WRITES this; the daemon
//                polls it every 100 ms. Writes MUST be atomic (unique temp file in the same
//                directory, then rename(2)) because several frontends may write concurrently
//                and the daemon may read mid-write. Concurrent read-modify-writes are
//                last-writer-wins by design; the file itself can never tear.
// status.json  — {"gain","muted","running","device"}. The daemon writes it (atomically) on
//                every change; frontends READ it to display the live level.

import Foundation

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/loudini", isDirectory: true)
let controlURL = configDir.appendingPathComponent("control.json")
let statusURL = configDir.appendingPathComponent("status.json")

func clampGain(_ n: Int) -> Int { min(100, max(0, n)) }

struct Control: Equatable {
    var gain: Int    // 0-100
    var muted: Bool
    var multiplier: Float { muted ? 0 : Float(gain) / 100 }
}

struct Status: Equatable {
    var gain: Int
    var muted: Bool
    var running: Bool
    /// Additive field: true only when the daemon's tap->gain->device pipeline is
    /// actually rendering. running && !pipeline usually means the System Audio
    /// Recording permission is missing or no output device is available.
    var pipeline: Bool
    var device: String
    /// Additive: why the pipeline is down — "" (up), "no-device", or error text.
    var reason: String
}

/// Lenient parse: malformed file or missing keys keep the previous values.
func readControl(previous: Control) -> Control? {
    guard let data = try? Data(contentsOf: controlURL),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var c = previous
    if let n = obj["gain"] as? NSNumber { c.gain = clampGain(n.intValue) }
    if let b = obj["muted"] as? Bool { c.muted = b }
    return c
}

/// The daemon's live status, or nil if it never wrote one (or the file is malformed).
///
/// Truthful even after a hard kill: the daemon stamps its pid, and if that
/// process is provably gone (ESRCH) the file's running/pipeline claims are
/// overridden to false — a SIGKILLed daemon can't strand a running:true file.
func readStatus() -> Status? {
    guard let data = try? Data(contentsOf: statusURL),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var running = obj["running"] as? Bool ?? false
    // Old files predate "pipeline"; assume it followed running to avoid false alarms.
    var pipeline = obj["pipeline"] as? Bool ?? running
    if running, let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 0,
       kill(pid, 0) == -1, errno == ESRCH {
        running = false
        pipeline = false
    }
    return Status(gain: clampGain((obj["gain"] as? NSNumber)?.intValue ?? 100),
                  muted: obj["muted"] as? Bool ?? false,
                  running: running,
                  pipeline: pipeline,
                  device: obj["device"] as? String ?? "",
                  reason: obj["reason"] as? String ?? "")
}

/// Atomic write: unique temp file in the same directory (thus same filesystem), then rename(2),
/// which atomically replaces the destination on APFS/HFS+. A reader sees either the old or the
/// new complete file, never a partial one; concurrent writers interleave but never tear it.
func atomicWrite(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
    do {
        try data.write(to: tmp)
    } catch {
        try? FileManager.default.removeItem(at: tmp)  // partial write (e.g. disk full)
        throw error
    }
    guard rename(tmp.path, url.path) == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        try? FileManager.default.removeItem(at: tmp)
        throw POSIXError(code)
    }
}

func writeControl(_ c: Control) throws {
    let obj: [String: Any] = ["gain": clampGain(c.gain), "muted": c.muted]
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try atomicWrite(data, to: controlURL)
}

/// Read-modify-write operations shared by the CLI and the menu-bar app.
/// Semantics mirror plugin/src/control.ts exactly: clamp 0-100, nudge also un-mutes.
enum ControlOps {
    /// Current control: file contents if valid, defaults {100, unmuted} otherwise.
    static func current() -> Control {
        readControl(previous: Control(gain: 100, muted: false)) ?? Control(gain: 100, muted: false)
    }

    /// gain += delta, clamped, and un-mute (nudging implies you want to hear it).
    /// delta itself is clamped to ±100 first so extreme values can't overflow Int.
    @discardableResult
    static func nudge(_ delta: Int) throws -> Control {
        var c = current()
        c.gain = clampGain(c.gain + min(100, max(-100, delta)))
        c.muted = false
        try writeControl(c)
        return c
    }

    @discardableResult
    static func toggleMute() throws -> Control {
        var c = current()
        c.muted.toggle()
        try writeControl(c)
        return c
    }

    @discardableResult
    static func set(gain: Int) throws -> Control {
        var c = current()
        c.gain = clampGain(gain)
        try writeControl(c)
        return c
    }
}
