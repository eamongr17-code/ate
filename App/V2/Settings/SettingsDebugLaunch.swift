import AteKit
import Foundation

/// What a drive's launch asks of the first-run and settings branch (``DebugLaunch``).
///
/// ``showsDebugDoor`` is the one member that exists outside `DEBUG`, because the staging sign-in it
/// gates is compiled into Beta as well.
enum SettingsDebugLaunch {
    /// False only when a parity drive asked for it (``DebugLaunch/Flag/hideDebugDoor``). Release has
    /// no debug door at all.
    static var showsDebugDoor: Bool {
        #if DEBUG || BETA
        DebugLaunch.isOn(.hideDebugDoor) == false
        #else
        false
        #endif
    }

    #if DEBUG
    /// `-ate-open first-run-handle` — the first-run handle screen, which has no back arrow and is
    /// otherwise only reachable by signing in with a brand-new Apple ID.
    static var opensFirstRunHandle: Bool { DebugLaunch.route?.screen == .firstRunHandle }
    #endif
}
