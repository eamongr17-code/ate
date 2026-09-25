import AteKit
import Foundation

/// A one-button sign-in as the seeded staging demo account.
///
/// **Why this exists.** Every V1 read needs a session (`anon` is revoked on all V1 tables, so an
/// unauthenticated read returns `[]`, not data), and a simulator cannot complete Sign in with Apple.
/// It is `Welcome`'s small "staging" door in Debug and Beta, and how every drive signs in.
///
/// **Why it is safe.** It is compiled only in `DEBUG || BETA`, and ``make(for:api:)`` returns `nil`
/// for any environment other than staging — so a Release build has neither the code nor the code
/// path. The credentials are the demo account already committed in `supabase/seed.sql`.
struct DebugStagingSignIn: Sendable {
    /// Signs in without a tap — how a sim drive reaches the app while auth is still a stub.
    /// `xcrun simctl launch … -ate-debug-signin`.
    static let autoSignInArgument = "-ate-debug-signin"

    let title: String
    private let action: @Sendable () async -> Void

    init(title: String, action: @escaping @Sendable () async -> Void) {
        self.title = title
        self.action = action
    }

    func signIn() async { await action() }

    var isAutoSignInRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(Self.autoSignInArgument)
    }

    #if DEBUG || BETA
    private static let email = "eamon@ate.test"
    private static let password = "atedemo123"

    static func make(for environment: AteEnvironment, api: AteAPIClient) -> DebugStagingSignIn? {
        guard environment.name == .staging else { return nil }
        return DebugStagingSignIn(title: "Sign in as \(email) (staging)") {
            do {
                try await api.supabase.auth.signIn(email: email, password: password)
            } catch {
                // Debug affordance: the failure surfaces as "still signed out", which is the honest
                // outcome and needs no UI of its own.
            }
        }
    }
    #else
    static func make(for environment: AteEnvironment, api: AteAPIClient) -> DebugStagingSignIn? { nil }
    #endif
}
