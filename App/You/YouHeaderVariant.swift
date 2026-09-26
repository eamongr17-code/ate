import Foundation

/// **The You header, two ways — a VISUAL PROTOTYPE, not for merge until Eamon picks.**
///
/// Eamon (2026-09-26): the avatar and the handle are too big, the gear sits too close to them, and a
/// long handle runs underneath it. `A` is the header as it ships today; `B` is the resized one —
/// a 56pt avatar, the handle at 26 on one line that truncates, and the gear moved into the row
/// with a fixed gap to the handle, so the two can never touch.
///
/// Debug only: `-ate-you-header B` picks B (anything else, or nothing, is A), and
/// `-ate-you-handle <handle>` stands a handle in for the one on file, so a long one can be
/// photographed without renaming an account. Both are `UserDefaults` argument-domain reads, which is
/// how a `-key value` pair arrives on a launch.
enum YouHeaderVariant: String {
    case a = "A"
    case b = "B"

    static var current: YouHeaderVariant {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "ate-you-header")?.uppercased() == "B" { return .b }
        #endif
        return .a
    }

    /// A handle to draw instead of the one on file, for the long-handle screenshot.
    static var handleOverride: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "ate-you-handle")
        #else
        nil
        #endif
    }
}
