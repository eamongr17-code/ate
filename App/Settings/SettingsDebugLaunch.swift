import Foundation

/// Launch arguments for the first-run and settings branch — the only way a drive reaches these
/// screens on a simulator that cannot be tapped from a shell.
///
/// Its own type rather than more cases on `ComposerDebugLaunch`: that file belongs to the composer
/// lane, and a shared enum is a merge conflict every time two lanes add a screen.
///
/// ``showsDebugDoor`` is the one member that exists outside `DEBUG`, because the staging sign-in it
/// gates is compiled into Beta as well.
enum SettingsDebugLaunch {
    /// `-ate-open-settings` — the Settings page, from the You tab.
    static let settingsArgument = "-ate-open-settings"
    /// …and the pages that hang off it.
    static let handleArgument = "-ate-open-handle"
    static let appearanceArgument = "-ate-open-appearance"
    static let aiArgument = "-ate-open-ai"
    static let blockedArgument = "-ate-open-blocked"
    /// `-ate-open-first-run-handle` — the first-run handle screen, which has no back arrow and is
    /// otherwise only reachable by signing in with a brand-new Apple ID.
    static let firstRunHandleArgument = "-ate-open-first-run-handle"
    /// `-ate-hide-debug-door` — hides the Debug/Beta staging sign-in on `Welcome`, so the parity
    /// screenshot is of exactly what a Release build draws.
    static let hideDebugDoorArgument = "-ate-hide-debug-door"

    /// False only when a parity drive asked for it. Release has no debug door at all.
    static var showsDebugDoor: Bool {
        #if DEBUG || BETA
        ProcessInfo.processInfo.arguments.contains(hideDebugDoorArgument) == false
        #else
        false
        #endif
    }

    #if DEBUG
    /// The settings page a drive asked for, or nil.
    static var page: SettingsPage? {
        if has(handleArgument) { return .handle(current: nil) }
        if has(appearanceArgument) { return .appearance }
        if has(aiArgument) { return .artificialIntelligence }
        if has(blockedArgument) { return .blocked }
        if has(settingsArgument) { return .root }
        return nil
    }

    static var opensFirstRunHandle: Bool { has(firstRunHandleArgument) }

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
    #endif
}
