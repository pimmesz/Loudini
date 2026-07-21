// Conflicts.swift — the one list of apps known to fight with Loudini, shared by the
// daemon's `doctor` and the menu-bar app's conflict row (same idiom as ControlFile.swift:
// one file compiled into both targets).
//
// Two DIFFERENT problems with two different fixes, hence two lists:
//   captureRivals  — they capture/re-render system audio too, so they double-capture with
//                    Loudini and feed back. That breaks audio: doctor FAILs on these.
//   mediaKeyRivals — they tap the volume keys too. Whoever installed their tap last sees
//                    the keys first, so these can starve Loudini (and vice versa). Only
//                    annoying: doctor WARNs.
//
// The problem text and the fix text live here next to the names because both frontends
// must tell the user the same thing about the same app — they used to disagree.
//
// Names are as `pgrep -x` (daemon) and NSRunningApplication.localizedName (app) see them,
// which for these apps is the same string. Only add an app whose process name you have
// actually confirmed on disk; a wrong name silently never matches.

import Foundation

enum Conflicts {
    static let captureRivals = ["Background Music"]
    static let mediaKeyRivals = ["MonitorControl", "BeardedSpice"]

    /// Every rival, capture problems first — they break audio outright, so when several
    /// are running that is the one worth naming.
    static let all = captureRivals + mediaKeyRivals

    static func isCaptureRival(_ name: String) -> Bool { captureRivals.contains(name) }

    /// What goes wrong, phrased for someone who just saw the app's name.
    static func problem(for name: String) -> String {
        isCaptureRival(name)
            ? "\(name) is running — it double-captures with Loudini and feeds back"
            : "\(name) is running and may intercept the volume keys"
    }

    /// The concrete fix for that problem.
    static func fixHint(for name: String) -> String {
        isCaptureRival(name)
            ? "quit/uninstall \(name); Loudini replaces it"
            : "disable volume-key handling in \(name), or launch the Loudini app after it"
    }
}
