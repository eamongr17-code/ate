import Foundation

/// **Which app the root draws** while the rebuild ships beside the current build (phase 2b): the
/// current app, or the rebuilt one under `App/V2/`. Cutover deletes this type with the old app.
///
/// The rebuilt app is only ever reachable in Debug and Beta builds — `isAvailable` is false in a
/// Release build, so nothing a person can set opens it there.
public enum AppGeneration: Equatable, Sendable {
    case current
    case new

    /// - Parameters:
    ///   - isAvailable: the build may open the new app at all (Debug and Beta).
    ///   - launchFlag: `-ate-v2` was passed — this launch opens the new app.
    ///   - isUITesting: a UI-test run, which starts from nothing: a preference left by a person or an
    ///     earlier test never decides which app a test lands in. Only the flag does.
    ///   - preference: the phone's choice (``AtePreferences/opensNewApp``).
    public static func resolve(
        isAvailable: Bool,
        launchFlag: Bool,
        isUITesting: Bool,
        preference: Bool
    ) -> AppGeneration {
        guard isAvailable else { return .current }
        if launchFlag { return .new }
        if isUITesting { return .current }
        return preference ? .new : .current
    }
}
