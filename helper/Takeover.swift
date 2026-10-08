// Takeover.swift: when a daemon waiting on daemon.lock should stop waiting and exit, kept
// out of loudini-helper.swift so scripts/test.sh can check it. Pure Foundation.

import Foundation

/// Identifies the binary a daemon started from. A rebuild or an update replaces or
/// re-signs the file, which changes its inode or its modification time.
struct ExecutableStamp: Equatable {
    var inode: UInt64
    var modified: TimeInterval
}

/// Nil when the file is gone, which counts as changed.
func executableStamp(atPath path: String) -> ExecutableStamp? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
          let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
    return ExecutableStamp(inode: inode, modified: modified)
}

/// Why a waiting daemon should exit instead of taking over later, or nil to keep waiting.
/// A newer binary on disk: its spawner (launchd, the app, the plugin) starts that one. A
/// parent that is gone (only for a waiter launchd did not start, parent pid 1): it would
/// take over audio with nothing owning it.
func waiterGiveUpReason(startStamp: ExecutableStamp?, nowStamp: ExecutableStamp?,
                        startParent: pid_t, nowParent: pid_t) -> String? {
    if startParent != 1, nowParent != startParent { return "its parent (pid \(startParent)) is gone" }
    if let startStamp, nowStamp != startStamp { return "its binary changed on disk" }
    return nil
}
