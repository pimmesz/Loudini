// StallMath.swift: the render-stall watchdog's decisions as pure functions, kept out of
// loudini-helper.swift so scripts/test.sh can check them with synthetic clocks.

import Foundation

enum StallVerdict: Equatable {
    /// The heartbeat moved, or nothing is playing: restart the quiet window.
    case progressing
    /// Quiet, but not yet for the whole window.
    case waiting
    /// Quiet for the whole window while an app was producing output.
    case stalled(window: TimeInterval)
}

/// One watchdog sample. `quietSince` is when the heartbeat last moved or was re-armed,
/// on the uptime clock. A pipeline that never rendered (`ticks == 0`) gets the longer
/// startup window but is never exempt. Until `pausedUntil` (just after the Mac slept)
/// nothing counts: in DarkWake the output does not run while apps still report output.
func stallVerdict(ticks: UInt64, lastTicks: UInt64, quietSince: TimeInterval, now: TimeInterval,
                  anyAppActive: Bool, pausedUntil: TimeInterval,
                  steadyWindow: TimeInterval, startupWindow: TimeInterval) -> StallVerdict {
    if ticks != lastTicks || !anyAppActive || now < pausedUntil { return .progressing }
    let window = ticks == 0 ? startupWindow : steadyWindow
    return now - quietSince >= window ? .stalled(window: window) : .waiting
}

/// Seconds the Mac slept between two samples: how much further the wall clock moved than
/// the uptime clock, which stops during sleep. A small difference is clock jitter.
func sleptSeconds(wallDelta: TimeInterval, uptimeDelta: TimeInterval) -> TimeInterval {
    let gap = wallDelta - uptimeDelta
    return gap > 5 ? gap : 0
}

/// Seconds to wait before rebuilding after a stall: the normal grace, stretched so that
/// stall rebuilds run at most once per cooldown.
func stallRebuildWait(lastRebuild: TimeInterval?, now: TimeInterval,
                       grace: TimeInterval, cooldown: TimeInterval) -> TimeInterval {
    guard let last = lastRebuild else { return grace }
    return max(grace, last + cooldown - now)
}
