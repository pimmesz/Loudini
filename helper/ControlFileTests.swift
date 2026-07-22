// ControlFileTests.swift — contract regression tests for ControlFile.swift.
//
// ControlFile.swift is the one file linked into BOTH the daemon and the menu-bar app, and
// it encodes the invariants BUILD.md calls non-negotiable: atomic writes, lenient parsing,
// clamping, and telling the truth about a dead daemon. Nothing enforced any of them until
// this file existed. It is pure Foundation file+JSON with no Core Audio, so it needs no
// audio hardware and no TCC grants — plain `swiftc` is enough (see scripts/test.sh).
//
// Deliberately no XCTest and no SPM: this repo has no Package.swift and builds everything
// with a bare swiftc line (menubar/build-app.sh), so a hand-rolled assert runner keeps the
// toolchain exactly as small as it already is.

import Foundation

// MARK: - the assert runner

private var failures: [String] = []
private var checks = 0

private func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    guard !ok else { return }
    let d = detail()
    failures.append(d.isEmpty ? label : "\(label) — \(d)")
}

/// Optional on both sides so a test can assert straight against a `readControl(...)?.x`
/// without unwrapping first; a nil where a value was expected simply fails the check.
private func checkEqual<T: Equatable>(_ label: String, _ got: T?, _ want: T?) {
    check(label, got == want, "got \(String(describing: got)), want \(String(describing: want))")
}

private func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data("REFUSING TO RUN: \(message)\n".utf8))
    exit(2)  // scripts/test.sh checks for exactly this code to prove the guard works
}

// MARK: - safety: never touch a real ~/.config/loudini

/// These tests WRITE control.json and status.json, so running them against a real home
/// would overwrite the developer's live master + per-app settings.
///
/// The override must be CFFIXED_USER_HOME, not HOME. `configDir` (ControlFile.swift:14)
/// comes from `homeDirectoryForCurrentUser`, which asks OS directory services and ignores
/// $HOME entirely — a HOME override looks like it works and silently does nothing. It also
/// has to be in the environment before this process starts: `configDir` is a lazily
/// initialised global, so anything that reads it ahead of a setenv() freezes the real path.
private func requireSandboxedHome() {
    guard let sandbox = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
          !sandbox.isEmpty else {
        refuse("CFFIXED_USER_HOME is not set, so these tests would write \(configDir.path). "
             + "Run them via scripts/test.sh, which points that at a throwaway directory.")
    }
    // Resolve symlinks on BOTH sides before comparing: /tmp and /var are symlinks into
    // /private, and CoreFoundation hands back the un-prefixed form, so comparing the raw
    // strings reports a false mismatch for a perfectly good sandbox.
    let root = URL(fileURLWithPath: sandbox).resolvingSymlinksInPath().path
    let actual = configDir.resolvingSymlinksInPath().path
    guard actual.hasPrefix(root + "/") else {
        refuse("config dir \(actual) is outside the sandbox \(root).")
    }
}

// MARK: - fixtures

/// Put an exact byte string on disk. Deliberately a plain write rather than atomicWrite:
/// these tests arrange raw and sometimes malformed input that atomicWrite could never emit.
private func writeRaw(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

private func removeFixtures() {
    try? FileManager.default.removeItem(at: controlURL)
    try? FileManager.default.removeItem(at: statusURL)
}

/// A pid that is provably gone: run /usr/bin/true and wait for it to be reaped. readStatus's
/// ESRCH branch needs a genuinely dead pid — a made-up number could hit a live process and
/// make the test pass or fail for the wrong reason.
private func deadPID() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! p.run()
    p.waitUntilExit()
    return Int(p.processIdentifier)
}

// MARK: - clamping and multipliers

private func testClampGain() {
    checkEqual("clamp -1 to 0", clampGain(-1), 0)
    checkEqual("clamp 0 stays", clampGain(0), 0)
    checkEqual("clamp 100 stays", clampGain(100), 100)
    checkEqual("clamp 101 to 100", clampGain(101), 100)
    checkEqual("clamp Int.min", clampGain(Int.min), 0)
    checkEqual("clamp Int.max", clampGain(Int.max), 100)
}

private func testMultiplier() {
    // A mute must be a hard zero, not a small gain — anything else leaks audio.
    checkEqual("muted master is silent", Control(gain: 100, muted: true).multiplier, 0)
    checkEqual("unmuted master scales", Control(gain: 50, muted: false).multiplier, 0.5)
    checkEqual("muted app is silent", AppOverride(gain: 100, muted: true).multiplier, 0)
    checkEqual("unmuted app scales", AppOverride(gain: 25, muted: false).multiplier, 0.25)
}

// MARK: - writeControl

/// The regression from 2bddc99: a master-only volume change must not wipe per-app overrides.
/// Every frontend does a read-modify-write of the whole Control, so if writeControl drops
/// `apps` the user silently loses all their per-app settings on the next volume nudge.
private func testWriteControlPreservesApps() {
    removeFixtures()
    let seeded = Control(gain: 50, muted: false,
                         apps: ["com.spotify.client": AppOverride(gain: 30, muted: false),
                                "com.apple.Safari": AppOverride(gain: 100, muted: true)])
    try! writeControl(seeded)

    // …now a master-only change, exactly the way the CLI and menu-bar app make one.
    var after = ControlOps.current()
    after.gain = 80
    try! writeControl(after)

    let reread = ControlOps.current()
    checkEqual("master write applied", reread.gain, 80)
    checkEqual("master write keeps app count", reread.apps.count, 2)
    checkEqual("master write keeps spotify override",
               reread.apps["com.spotify.client"], AppOverride(gain: 30, muted: false))
    checkEqual("master write keeps safari mute",
               reread.apps["com.apple.Safari"], AppOverride(gain: 100, muted: true))
}

private func testWriteControlShape() {
    removeFixtures()
    // With no overrides the `apps` key is omitted entirely, so a master-only user's file
    // stays byte-identical to the pre-per-app shape and older readers keep working.
    try! writeControl(Control(gain: 55, muted: true))
    checkEqual("master-only file keeps the legacy shape",
               try? String(contentsOf: controlURL, encoding: .utf8),
               #"{"gain":55,"muted":true}"#)

    // sortedKeys is what makes the file byte-stable for a given Control, which is what
    // lets callers compare two serialisations to detect "nothing actually changed".
    try! writeControl(Control(gain: 10, muted: false,
                              apps: ["z": AppOverride(gain: 1, muted: false),
                                     "a": AppOverride(gain: 2, muted: true)]))
    checkEqual("keys sorted at every level",
               try? String(contentsOf: controlURL, encoding: .utf8),
               #"{"apps":{"a":{"gain":2,"muted":true},"z":{"gain":1,"muted":false}},"gain":10,"muted":false}"#)

    // Clamping happens on the way out too, not only on the way in.
    try! writeControl(Control(gain: 900, muted: false, apps: ["a": AppOverride(gain: -5, muted: false)]))
    let clamped = ControlOps.current()
    checkEqual("write clamps master gain", clamped.gain, 100)
    checkEqual("write clamps app gain", clamped.apps["a"]?.gain, 0)
}

// MARK: - readControl leniency

private func testReadControlLeniency() {
    let previous = Control(gain: 42, muted: true,
                           apps: ["com.old.app": AppOverride(gain: 10, muted: false)])

    // An absent `apps` key means "no opinion", so the caller keeps its last-good map.
    writeRaw(#"{"gain":70,"muted":false}"#, to: controlURL)
    let absent = readControl(previous: previous)
    checkEqual("absent apps keeps previous map", absent?.apps, previous.apps)
    checkEqual("absent apps still reads gain", absent?.gain, 70)

    // An explicit empty object is a real instruction: clear it.
    writeRaw(#"{"gain":70,"muted":false,"apps":{}}"#, to: controlURL)
    checkEqual("explicit {} clears apps", readControl(previous: previous)?.apps, [String: AppOverride]())

    // One unusable row must not take the good ones down with it.
    writeRaw(#"{"apps":{"good":{"gain":25},"bad":"not-an-object"}}"#, to: controlURL)
    let mixed = readControl(previous: previous)
    checkEqual("bad row drops only itself", mixed?.apps.count, 1)
    checkEqual("good row survives", mixed?.apps["good"], AppOverride(gain: 25, muted: false))

    // An empty bundle id can never map to a real app, so it is ignored.
    writeRaw(#"{"apps":{"":{"gain":25},"ok":{"gain":50}}}"#, to: controlURL)
    let emptyKey = readControl(previous: previous)
    checkEqual("empty bundle id ignored", emptyKey?.apps.count, 1)
    check("empty bundle id not stored", emptyKey?.apps[""] == nil)

    // Out-of-range gains from a hand-edited or corrupt file are clamped on read.
    writeRaw(#"{"gain":999,"apps":{"hot":{"gain":420},"cold":{"gain":-7}}}"#, to: controlURL)
    let ranged = readControl(previous: previous)
    checkEqual("master gain clamped on read", ranged?.gain, 100)
    checkEqual("app gain clamped high", ranged?.apps["hot"]?.gain, 100)
    checkEqual("app gain clamped low", ranged?.apps["cold"]?.gain, 0)

    // The daemon polls every 100 ms and can catch a file mid-write, so unparseable input
    // must return nil (caller keeps its last good value) rather than reset the volume.
    writeRaw(#"{"gain":70,"mut"#, to: controlURL)
    check("truncated JSON returns nil", readControl(previous: previous) == nil)
    writeRaw("", to: controlURL)
    check("empty file returns nil", readControl(previous: previous) == nil)
    writeRaw("[1,2,3]", to: controlURL)
    check("non-object JSON returns nil", readControl(previous: previous) == nil)
    removeFixtures()
    check("missing file returns nil", readControl(previous: previous) == nil)

    // …and the fallback that leniency exists to protect: defaults, never a crash.
    checkEqual("current() falls back to defaults", ControlOps.current(), Control(gain: 100, muted: false))
}

// MARK: - ControlOps

private func testNudge() {
    removeFixtures()
    // Nudging implies "I want to hear this", so it must also clear mute.
    try! writeControl(Control(gain: 40, muted: true))
    let up = try! ControlOps.nudge(6)
    checkEqual("nudge adds the delta", up.gain, 46)
    check("nudge un-mutes", up.muted == false)

    // The delta is clamped to ±100 before it is added, so a wild value can never overflow
    // Int on its way into clampGain.
    try! writeControl(Control(gain: 50, muted: false))
    checkEqual("huge positive delta saturates", try! ControlOps.nudge(Int.max).gain, 100)
    try! writeControl(Control(gain: 50, muted: false))
    checkEqual("huge negative delta saturates", try! ControlOps.nudge(Int.min).gain, 0)

    // A nudge is a master-only write, so it must keep per-app overrides too.
    try! writeControl(Control(gain: 50, muted: false, apps: ["a": AppOverride(gain: 20, muted: false)]))
    checkEqual("nudge keeps apps", try! ControlOps.nudge(10).apps["a"], AppOverride(gain: 20, muted: false))
}

// MARK: - per-app mutators (Phase 3)

/// The `apps`-map mutators only had coverage through nudge before; these pin the
/// seed-a-default, clamp, empty-id-no-op, target-isolation and master-preservation rules.
private func testPerAppMutators() {
    removeFixtures()

    // setApp seeds a default (100/false) for a new app, then clamps the gain.
    try! writeControl(Control(gain: 50, muted: false))
    let a1 = try! ControlOps.setApp("com.x", gain: 250)
    checkEqual("setApp seeds default + clamps gain", a1.apps["com.x"], AppOverride(gain: 100, muted: false))
    checkEqual("setApp leaves master gain", a1.gain, 50)

    // An empty bundle id is a no-op — there is nothing stable to target. Check on a fresh
    // control so "added no entry" shows as an empty map (setApp returns current() unchanged).
    removeFixtures()
    try! writeControl(Control(gain: 50, muted: false))
    check("setApp empty id is a no-op", try! ControlOps.setApp("", gain: 30).apps.isEmpty)

    // toggleAppMute seeds a default then flips only the muted flag.
    removeFixtures()
    try! writeControl(Control(gain: 60, muted: false))
    checkEqual("toggleAppMute seeds default + flips", try! ControlOps.toggleAppMute("com.y").apps["com.y"],
               AppOverride(gain: 100, muted: true))
    check("toggleAppMute flips back", try! ControlOps.toggleAppMute("com.y").apps["com.y"]?.muted == false)
    check("toggleAppMute empty id is a no-op", try! ControlOps.toggleAppMute("").apps.count == 1)

    // toggleAppMute touches only its target.
    try! writeControl(Control(gain: 60, muted: false,
                              apps: ["a": AppOverride(gain: 20, muted: false),
                                     "b": AppOverride(gain: 30, muted: false)]))
    let only = try! ControlOps.toggleAppMute("a")
    check("toggleAppMute flips only the target", only.apps["a"]?.muted == true)
    checkEqual("toggleAppMute leaves siblings", only.apps["b"], AppOverride(gain: 30, muted: false))

    // resetApps clears every override but leaves master gain/mute alone.
    try! writeControl(Control(gain: 40, muted: true, apps: ["a": AppOverride(gain: 20, muted: false)]))
    let r = try! ControlOps.resetApps()
    check("resetApps clears the apps map", r.apps.isEmpty)
    checkEqual("resetApps keeps master gain", r.gain, 40)
    check("resetApps keeps master mute", r.muted == true)

    // Master-only writes (set / toggleMute) must never drop the apps map, and set clamps.
    try! writeControl(Control(gain: 50, muted: false, apps: ["a": AppOverride(gain: 20, muted: false)]))
    checkEqual("set(gain:) keeps apps", try! ControlOps.set(gain: 70).apps["a"], AppOverride(gain: 20, muted: false))
    try! writeControl(Control(gain: 50, muted: false, apps: ["a": AppOverride(gain: 20, muted: false)]))
    checkEqual("toggleMute keeps apps", try! ControlOps.toggleMute().apps["a"], AppOverride(gain: 20, muted: false))
    try! writeControl(Control(gain: 50, muted: false))
    checkEqual("set(gain:) clamps", try! ControlOps.set(gain: 250).gain, 100)
}

// MARK: - readStatus

/// A SIGKILLed daemon leaves a stale `running:true` file behind. readStatus stamps and
/// checks the pid so a dead daemon can never keep claiming it is running.
private func testReadStatusDeadDaemon() {
    let dead = deadPID()
    writeRaw(#"""
    {"gain":80,"muted":false,"running":true,"pipeline":true,"device":"Scarlett","pid":\#(dead),
     "apps":[{"bundleID":"x","name":"X","pid":1,"gain":50,"muted":false,"active":true}]}
    """#, to: statusURL)
    let s = readStatus()
    check("dead daemon forces running false", s?.running == false)
    check("dead daemon forces pipeline false", s?.pipeline == false)
    checkEqual("dead daemon drops the stale roster", s?.apps.count, 0)
    checkEqual("dead daemon still reports gain", s?.gain, 80)
}

private func testReadStatusRoster() {
    // running:false skips the liveness check, so the roster is parsed as written — which
    // is how we exercise the roster parser without needing a live daemon.
    writeRaw(#"""
    {"running":false,"apps":[
      {"bundleID":"a","name":"A","pid":99999999999999,"gain":50,"muted":false,"active":true},
      "junk",
      {"bundleID":"b","name":"B","pid":42,"gain":300,"muted":true,"active":false}]}
    """#, to: statusURL)
    let s = readStatus()
    checkEqual("malformed roster row drops only itself", s?.apps.count, 2)
    // An out-of-range pid would trap pid_t() at the menu-bar sink, so it is bounded to 0.
    checkEqual("out-of-range pid bounded to 0", s?.apps.first?.pid, 0)
    checkEqual("in-range pid preserved", s?.apps.last?.pid, 42)
    checkEqual("roster gain clamped", s?.apps.last?.gain, 100)
    check("roster mute read", s?.apps.last?.muted == true)

    // Old files predate `pipeline`; it follows running so an upgrade raises no false alarm.
    writeRaw(#"{"gain":30,"muted":false,"running":false,"device":"X"}"#, to: statusURL)
    check("missing pipeline follows running", readStatus()?.pipeline == false)

    removeFixtures()
    check("missing status returns nil", readStatus() == nil)
}

/// `reason` drives the menu-bar's "why capture is broken" message, so the parser must
/// surface it. running:false skips the liveness probe, leaving reason parsed as written.
private func testReadStatusReason() {
    writeRaw(#"{"running":false,"pipeline":false,"reason":"no-device","device":"X"}"#, to: statusURL)
    checkEqual("reason is parsed", readStatus()?.reason, "no-device")
    writeRaw(#"{"running":false}"#, to: statusURL)
    checkEqual("missing reason defaults empty", readStatus()?.reason, "")
    removeFixtures()
}

// MARK: - atomicWrite

private func testAtomicWriteLeavesNoResidue() {
    removeFixtures()
    let target = configDir.appendingPathComponent("atomic-probe.json")
    let payload = Data(#"{"hello":"world"}"#.utf8)
    try! atomicWrite(payload, to: target)
    checkEqual("atomic write lands the exact bytes", try? Data(contentsOf: target), payload)

    // The temp file is .<name>.<pid>.<uuid>.tmp in the same directory. After a successful
    // rename none may survive, or a daemon writing every 100 ms slowly fills the config dir.
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: configDir.path)) ?? [])
        .filter { $0.hasSuffix(".tmp") }
    check("no .tmp residue after a successful write", leftovers.isEmpty, "found \(leftovers)")

    // Overwriting must replace the file wholesale — a shorter payload must not leave the
    // tail of the longer one behind, which is the classic in-place-truncate bug.
    let shorter = Data(#"{"a":1}"#.utf8)
    try! atomicWrite(shorter, to: target)
    checkEqual("atomic overwrite replaces, never appends", try? Data(contentsOf: target), shorter)

    try? FileManager.default.removeItem(at: target)
}

// MARK: - status.json serialisation

private func testAppEntryJSON() {
    let json = appEntryJSON(AppEntry(bundleID: "com.x", name: "X", pid: 7,
                                     gain: 250, muted: false, active: true))
    checkEqual("appEntryJSON clamps gain", json["gain"] as? Int, 100)
    checkEqual("appEntryJSON keeps the bundle id", json["bundleID"] as? String, "com.x")
    // Byte-stable under sortedKeys, so the daemon can compare two serialisations to decide
    // whether anything actually changed before it rewrites status.json.
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    checkEqual("appEntryJSON is byte-stable", String(data: data, encoding: .utf8),
               #"{"active":true,"bundleID":"com.x","gain":100,"muted":false,"name":"X","pid":7}"#)
}

// MARK: - entry point

@main
struct ControlFileTests {
    static func main() {
        requireSandboxedHome()

        testClampGain()
        testMultiplier()
        testWriteControlPreservesApps()
        testWriteControlShape()
        testReadControlLeniency()
        testNudge()
        testPerAppMutators()
        testReadStatusDeadDaemon()
        testReadStatusRoster()
        testReadStatusReason()
        testAtomicWriteLeavesNoResidue()
        testAppEntryJSON()

        guard failures.isEmpty else {
            FileHandle.standardError.write(Data("FAILED \(failures.count) of \(checks) checks:\n".utf8))
            for f in failures { FileHandle.standardError.write(Data("  x \(f)\n".utf8)) }
            exit(1)
        }
        print("ok — \(checks) contract checks passed")
    }
}
