import AteKit
import Foundation

/// A one-button sign-in as a seeded staging demo account.
///
/// **Why this exists.** The feed needs a session to show anything at all (RLS is deny-by-default
/// for `anon`), and the real auth flow is a later brief. Without this, every Debug run of the app
/// shows the signed-out screen and nobody — engineer, QA, or Eamon — can look at the feed on a
/// device before auth ships. It is deleted the day the auth flow lands.
///
/// **Why it is safe.** It is compiled only in `DEBUG`, and ``make(for:api:)`` returns `nil` for any
/// environment other than staging, so a Release build has neither the code nor the code path. The
/// credentials are the demo account already committed in `supabase/seed.sql` — this reveals nothing
/// that isn't in the repo, and points at staging, which is the law for Debug builds.
struct DebugStagingSignIn: Sendable {
    /// Launch argument that signs in without a tap — how a sim drive or the future XCUITest smoke
    /// flow reaches the feed while auth is still a stub. `xcrun simctl launch … -ate-debug-signin`.
    static let autoSignInArgument = "-ate-debug-signin"

    let title: String
    private let action: @Sendable () async -> Void

    func signIn() async { await action() }

    var isAutoSignInRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(Self.autoSignInArgument)
    }

    #if DEBUG
    private static let email = "eamon@ate.test"
    private static let password = "atedemo123"

    static func make(for environment: AteEnvironment, api: AteAPIClient) -> DebugStagingSignIn? {
        guard environment.name == .staging else { return nil }
        return DebugStagingSignIn(title: "Sign in as \(email) (staging)") {
            do {
                try await api.supabase.auth.signIn(email: email, password: password)
            } catch {
                // Debug affordance: the failure surfaces as "still signed out", which is the
                // honest outcome and needs no UI of its own.
            }
        }
    }
    #else
    static func make(for environment: AteEnvironment, api: AteAPIClient) -> DebugStagingSignIn? { nil }
    #endif
}
