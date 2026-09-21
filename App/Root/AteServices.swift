import AteKit
import SwiftUI

/// **Everything the shell hands down.** One value, built once at the root, so every screen shares one
/// `AteAPIClient` — and therefore one URLSession and one auth session. A second client would mean the
/// sign-in path reached only half the app.
///
/// It is a struct of seams, not a container: each screen takes the one thing it needs.
@MainActor
struct AteServices {
    let environment: AteEnvironment
    let api: AteAPIClient
    let analytics: AnalyticsRecorder
    /// Present in Debug and Beta pointed at staging; `nil` everywhere else. Sign in with Apple is
    /// milestone 2 — until it lands this is the only way into a session.
    let debugSignIn: DebugStagingSignIn?

    init(environment: AteEnvironment) {
        let api = AteAPIClient(environment: environment)
        self.environment = environment
        self.api = api
        self.analytics = AteTelemetry.record
        self.debugSignIn = DebugStagingSignIn.make(for: environment, api: api)
    }

    /// True when there is a session token on hand. Cheap and synchronous — it may be expired, which
    /// the first real request resolves.
    var hasSession: Bool { api.isSignedIn }

    /// Which backend this build talks to. Debug only — a Release build must never display it, and
    /// this is the one place that decides that.
    var environmentFootnote: String? {
        #if DEBUG
        BuildStamp(environment: environment.name).summary(supabaseHost: environment.supabaseURL.host())
        #else
        nil
        #endif
    }
}
