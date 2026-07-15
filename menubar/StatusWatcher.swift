// StatusWatcher.swift — watches the daemon's status.json (ground truth) with a
// light 200 ms poll. A poll beats a file-system event source here: every atomic
// write replaces the inode, which silently detaches vnode-based sources.

import Foundation

final class StatusWatcher {
    private let queue = DispatchQueue(label: "gg.pim.loudini.menubar.status")
    private var timer: DispatchSourceTimer?
    private var last: Status?
    private var hasPolled = false
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
        let s = readStatus()
        guard s != last || !hasPolled else { return }
        hasPolled = true
        last = s
        DispatchQueue.main.async { self.onChange(s) }
    }
}
