// DeviceLevels.swift: the last master level per fixed-level output (a DAC or interface
// with no volume of its own), so switching back to it restores that level instead of
// inheriting whatever the previous output was at. Daemon-owned, stored in
// ~/.config/loudini/devices.json as {"<device UID>": {"gain": 0-100}}. Outputs with their
// own volume keep their level in hardware and are never stored here.

import Foundation

let deviceLevelsURL = configDir.appendingPathComponent("devices.json")

/// Lenient read: a missing or malformed file is an empty memory, a bad row is skipped.
func readDeviceLevels() -> [String: Int] {
    guard let data = try? Data(contentsOf: deviceLevelsURL),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
    var levels: [String: Int] = [:]
    for (uid, row) in obj {
        guard !uid.isEmpty, let gain = ((row as? [String: Any])?["gain"] as? NSNumber)?.intValue else { continue }
        levels[uid] = clampGain(gain)
    }
    return levels
}

func writeDeviceLevels(_ levels: [String: Int]) throws {
    let obj = levels.mapValues { ["gain": clampGain($0)] }
    try atomicWrite(JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), to: deviceLevelsURL)
}

/// What to do when the pipeline is built for an output. `previousUID` is the output the
/// last successful build used (nil right after the daemon starts). On a real switch the
/// outgoing fixed-level output's level is remembered, and the incoming one's remembered
/// level, if any, is returned to apply. A daemon start applies nothing: control.json
/// already holds the level the user last chose.
struct DeviceSwitchPlan: Equatable {
    var levels: [String: Int]
    var applyGain: Int?
}

func planDeviceSwitch(previousUID: String?, previousIsFixed: Bool, newUID: String, newIsFixed: Bool,
                      currentGain: Int, levels: [String: Int]) -> DeviceSwitchPlan {
    guard let previousUID, previousUID != newUID else { return DeviceSwitchPlan(levels: levels, applyGain: nil) }
    var next = levels
    if previousIsFixed { next[previousUID] = clampGain(currentGain) }
    let remembered = newIsFixed ? next[newUID] : nil
    return DeviceSwitchPlan(levels: next, applyGain: remembered == currentGain ? nil : remembered)
}
