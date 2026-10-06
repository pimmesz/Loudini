// StatusWatcher.swift — watches the daemon's status.json (ground truth) with a
// light 200 ms poll. A poll beats a file-system event source here: every atomic
// write replaces the inode, which silently detaches vnode-based sources.

import Foundation

final class StatusWatcher {
    private let queue = DispatchQueue(label: "gg.pim.loudini.menubar.status")
    private var timer: DispatchSourceTimer?
    private var last: Status?
    private var hasPolled = false
    private var lastSignature = ""
    /// The daemon pid from the last full read. A SIGKILLed daemon leaves status.json
    /// untouched, so an unchanged file still needs this liveness probe.
    private var lastPid: pid_t = 0
    private let onChange: (Status?) -> Void

    /// `onChange` is called on the main queue — immediately after start() with
    /// the initial state, then on every change (from ANY frontend).
    init(onChange: @escaping (Status?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.2)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        // Skip the read and parse while the file is unchanged (mtime + size), the same
        // check the daemon's ControlWatcher uses. A stat failure falls through to a read.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: statusURL.path) {
            let sig = "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attrs[.size] as? Int ?? 0)"
            if hasPolled, sig == lastSignature, !daemonGone() { return }
            lastSignature = sig
        }
        let s = readStatus()
        lastPid = statusPid()
        guard s != last || !hasPolled else { return }
        hasPolled = true
        last = s
        DispatchQueue.main.async { self.onChange(s) }
    }

    private func daemonGone() -> Bool {
        guard last?.running == true, lastPid > 0 else { return false }
        return kill(lastPid, 0) == -1 && errno == ESRCH
    }

    private func statusPid() -> pid_t {
        guard let data = try? Data(contentsOf: statusURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return (obj["pid"] as? NSNumber)?.int32Value ?? 0
    }
}
