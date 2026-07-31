// ControlFile.swift — the Loudini control-file contract, shared by every Swift frontend
// (the loudini-helper daemon/CLI and the menu-bar app; plugin/src/control.ts mirrors it in TS).
//
// control.json: {"gain": <int 0-100>, "muted": <bool>,
//                "apps"?: {"<bundleID>": {"gain": <int 0-100>, "muted": <bool>}}}. Any frontend
//                WRITES this; the daemon polls it every 100 ms. Writes MUST be atomic (unique
//                temp file in the same directory, then rename(2)) because several frontends may
//                write concurrently and the daemon may read mid-write. A frontend that does not
//                own `apps` must merge it forward, never replace the document, or it wipes every
//                per-app override. Wrap the read-modify-write in withControlLock (below): the
//                rename stops a torn file but not a lost update.
// status.json:   {"gain","muted","running","pipeline","device","pid","reason"?,"apps"}, see
//                `struct Status` below, which is the contract. The daemon writes it (atomically)
//                on every change; frontends READ it to display the live level. `pid` is not a
//                Status field: readStatus() uses it to force running:false when that process is
//                gone, so a hard-killed daemon cannot leave a status claiming it still works.

import Foundation

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/loudini", isDirectory: true)
let controlURL = configDir.appendingPathComponent("control.json")
let statusURL = configDir.appendingPathComponent("status.json")

func clampGain(_ n: Int) -> Int { min(100, max(0, n)) }

/// One per-app override from control.json's `apps` map (Phase 2). Effective
/// per-app level = master × app; a muted app contributes zero before the master
/// multiply. `gain`/`muted` here are strictly a PRE-master attenuation.
struct AppOverride: Equatable {
    var gain: Int    // 0-100
    var muted: Bool
    var multiplier: Float { muted ? 0 : Float(gain) / 100 }
}

struct Control: Equatable {
    var gain: Int    // 0-100 (master)
    var muted: Bool  // master
    /// Per-app overrides keyed by bundle id. Absent app ⇒ rides master only.
    /// Backward compatible: an old control.json without `apps` yields [:].
    var apps: [String: AppOverride] = [:]
    var multiplier: Float { muted ? 0 : Float(gain) / 100 }
}

/// One row of the live "producing audio" roster the daemon publishes in
/// status.json (Phase 1 of the per-app-volume feature). Read-only for frontends:
/// they render straight from this array without their own Core Audio access.
struct AppEntry: Equatable {
    var bundleID: String   // stable id, "" for sources without a bundle (CLI/helper audio)
    var name: String       // localizedName, or a bundle-id / process-name fallback
    var pid: Int           // a representative live pid for the app
    var gain: Int          // applied per-app override, 0-100 (default 100 when unset)
    var muted: Bool        // applied per-app mute (default false when unset)
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
    // `apps` is lenient like the rest: absent or malformed keeps the previous
    // map (last-good), an explicit {} clears it, and individual bad rows are
    // dropped without discarding the good ones. Keyed by bundle id; empty keys
    // are ignored (can't map to a real app).
    if let appsObj = obj["apps"] as? [String: Any] {
        var m: [String: AppOverride] = [:]
        for (bid, v) in appsObj {
            guard !bid.isEmpty, let r = v as? [String: Any] else { continue }
            m[bid] = AppOverride(gain: clampGain((r["gain"] as? NSNumber)?.intValue ?? 100),
                                 muted: r["muted"] as? Bool ?? false)
        }
        c.apps = m
    }
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
    guard let rows = raw as? [Any] else { return [] }
    // compactMap so a single malformed element drops only that row, not the
    // entire roster — true lenient parse.
    return rows.compactMap { row -> AppEntry? in
        guard let r = row as? [String: Any] else { return nil }
        // Bound the pid to the valid pid_t range — an out-of-range value from a
        // corrupt/hostile file would trap pid_t() at the menu-bar sink.
        let rawPid = (r["pid"] as? NSNumber)?.intValue ?? 0
        let pid = (0...Int(pid_t.max)).contains(rawPid) ? rawPid : 0
        return AppEntry(bundleID: r["bundleID"] as? String ?? "",
                 name: r["name"] as? String ?? "",
                 pid: pid,
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
    var obj: [String: Any] = ["gain": clampGain(c.gain), "muted": c.muted]
    // Preserve per-app overrides across master-only writes (the CLI/menu-bar
    // read-modify-write the whole Control, so dropping `apps` here would wipe a
    // user's per-app settings on any master volume change). Omitted when empty
    // to keep the file byte-identical to the pre-Phase-2 shape for master users.
    if !c.apps.isEmpty {
        obj["apps"] = c.apps.mapValues { ["gain": clampGain($0.gain), "muted": $0.muted] }
    }
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try atomicWrite(data, to: controlURL)
}

/// Hold an exclusive cross-process lock around a control.json read-modify-write,
/// so overlapping writers (the daemon's publishGain, the CLI, and the menu-bar
/// app) don't lose each other's updates. The atomic rename in writeControl stops
/// a torn file but not a lost update — a per-app override set between another
/// writer's read and its rename would be silently dropped without this. Mirrors
/// DDC.withLock (brightness.lock). Fail-open: proceed unlocked if the lock can't
/// be taken.
func withControlLock<T>(_ body: () throws -> T) rethrows -> T {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let fd = open(configDir.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return try body() }
    defer { close(fd) }   // closing releases the flock; the kernel also drops it on exit
    flock(fd, LOCK_EX)
    return try body()
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
        try withControlLock {
            var c = current()
            c.gain = clampGain(c.gain + min(100, max(-100, delta)))
            c.muted = false
            try writeControl(c)
            return c
        }
    }

    @discardableResult
    static func toggleMute() throws -> Control {
        try withControlLock {
            var c = current()
            c.muted.toggle()
            try writeControl(c)
            return c
        }
    }

    @discardableResult
    static func set(gain: Int) throws -> Control {
        try withControlLock {
            var c = current()
            c.gain = clampGain(gain)
            try writeControl(c)
            return c
        }
    }

    // MARK: per-app overrides (Phase 3) — read-modify-write control.json's `apps`
    // map, keyed by bundle id. Shared by the menu-bar rows and the `loudini app`
    // CLI so both write the exact same shape. An empty bundle id is a no-op
    // (readControl ignores empty keys — there's nothing stable to target).

    @discardableResult
    static func setApp(_ bundleID: String, gain: Int) throws -> Control {
        try withControlLock {
            var c = current()
            guard !bundleID.isEmpty else { return c }
            var o = c.apps[bundleID] ?? AppOverride(gain: 100, muted: false)
            o.gain = clampGain(gain)
            c.apps[bundleID] = o
            try writeControl(c)
            return c
        }
    }

    @discardableResult
    static func toggleAppMute(_ bundleID: String) throws -> Control {
        try withControlLock {
            var c = current()
            guard !bundleID.isEmpty else { return c }
            var o = c.apps[bundleID] ?? AppOverride(gain: 100, muted: false)
            o.muted.toggle()
            c.apps[bundleID] = o
            try writeControl(c)
            return c
        }
    }

    /// "Reset all apps to 100%" — clears the whole `apps` map so every app rides
    /// master only again. Master gain/mute are untouched.
    @discardableResult
    static func resetApps() throws -> Control {
        try withControlLock {
            var c = current()
            c.apps = [:]
            try writeControl(c)
            return c
        }
    }
}
