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

/// One row of the live "producing audio" roster the daemon publishes in
/// status.json (Phase 1 of the per-app-volume feature). Read-only for frontends:
/// they render straight from this array without their own Core Audio access.
struct AppEntry: Equatable {
    var bundleID: String   // stable id, "" for sources without a bundle (CLI/helper audio)
    var name: String       // localizedName, or a bundle-id / process-name fallback
    var pid: Int           // a representative live pid for the app
    var gain: Int          // applied per-app override, 0-100 (Phase 1: always 100)
    var muted: Bool        // applied per-app mute (Phase 1: always false)
    var active: Bool       // IsRunningOutput now (false = lingering in the grace window)
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
    /// Additive: the live roster of apps currently producing audio (or lingering
    /// in the anti-flicker grace window). Empty when nothing is playing or the
    /// daemon is gone.
    var apps: [AppEntry]
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
    var deadDaemon = false
    if running, let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 0,
       kill(pid, 0) == -1, errno == ESRCH {
        running = false
        pipeline = false
        deadDaemon = true
    }
    // A provably-dead daemon can't have a live roster — drop it rather than show
    // a stale "what's playing" list from a status file nobody is updating.
    let apps = deadDaemon ? [] : parseApps(obj["apps"])
    return Status(gain: clampGain((obj["gain"] as? NSNumber)?.intValue ?? 100),
                  muted: obj["muted"] as? Bool ?? false,
                  running: running,
                  pipeline: pipeline,
                  device: obj["device"] as? String ?? "",
                  reason: obj["reason"] as? String ?? "",
                  apps: apps)
}

/// Lenient parse of the status.json `apps` array; unknown/missing keys default.
private func parseApps(_ raw: Any?) -> [AppEntry] {
    guard let rows = raw as? [[String: Any]] else { return [] }
    return rows.map { r in
        AppEntry(bundleID: r["bundleID"] as? String ?? "",
                 name: r["name"] as? String ?? "",
                 pid: (r["pid"] as? NSNumber)?.intValue ?? 0,
                 gain: clampGain((r["gain"] as? NSNumber)?.intValue ?? 100),
                 muted: r["muted"] as? Bool ?? false,
                 active: r["active"] as? Bool ?? true)
    }
}

/// Serialize a roster entry to the status.json shape (daemon-side).
func appEntryJSON(_ a: AppEntry) -> [String: Any] {
    ["bundleID": a.bundleID, "name": a.name, "pid": a.pid,
     "gain": clampGain(a.gain), "muted": a.muted, "active": a.active]
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
