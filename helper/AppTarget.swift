// AppTarget.swift: pure CLI argument helpers, kept out of loudini-helper.swift (which
// imports Core Audio) so scripts/test.sh can compile and table-test them.

import Foundation

/// A CLI step or per-app level: an integer in 0-100, or nil (the caller prints usage).
func parsePercent(_ s: String) -> Int? {
    guard let n = Int(s), (0...100).contains(n) else { return nil }
    return n
}

enum MuteAction: Equatable {
    case toggle
    case set(Bool)
}

func parseMuteAction(_ args: [String]) -> MuteAction? {
    switch args {
    case []: return .toggle
    case ["on"]: return .set(true)
    case ["off"]: return .set(false)
    default: return nil
    }
}

/// Resolve a user-typed `app` target to a bundle id. Bundle id is exact
/// (and usable even when the app isn't in the roster: you can pre-set a
/// silent app); a name is matched case-insensitively over the live roster
/// (exact name, then substring, then bundle-id substring). Falls back to
/// treating a dotted token as a bundle id so a not-yet-playing app is still
/// addressable. nil when nothing plausibly matches. Roster hits with an
/// empty bundle id (bundle-less sources like raw CLI/helper audio) are
/// skipped: there's no stable key to write, so set/mute would silently
/// no-op on "".
func resolveAppTarget(_ token: String, _ roster: [AppEntry]) -> String? {
    // Reject the empty token up front. Without this, the fuzzy `.contains(lower)`
    // passes below match every entry (`"x".contains("") == true`), so `app "" set`
    // would silently address the first roster app instead of failing.
    guard !token.isEmpty else { return nil }
    if roster.contains(where: { $0.bundleID == token }) { return token }
    let lower = token.lowercased()
    // Every fuzzy pass skips bundle-less sources *inside* the predicate so it
    // keeps scanning to a later addressable match instead of stopping on the
    // first name/id hit and then failing the guard.
    if let hit = roster.first(where: { !$0.bundleID.isEmpty && $0.name.lowercased() == lower }) {
        return hit.bundleID
    }
    if let hit = roster.first(where: { !$0.bundleID.isEmpty && $0.name.lowercased().contains(lower) }) {
        return hit.bundleID
    }
    if let hit = roster.first(where: { !$0.bundleID.isEmpty && $0.bundleID.lowercased().contains(lower) }) {
        return hit.bundleID
    }
    return token.contains(".") ? token : nil
}
