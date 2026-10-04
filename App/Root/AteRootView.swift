import AteKit
import SwiftUI

/// **The app's root.** Resolves the build's environment into either the shell or a loud, readable
/// configuration error — a misconfigured checkout must explain itself, not crash.
struct AteRootView: View {
    let environment: Result<AteEnvironment, Error>
    /// Built once. The shell is rebuilt on every sign-out, and the services under it must not be —
    /// one client, one auth session, for the life of the process.
    @State private var services: AteServices?
    /// Bumped when a session ends, so the next person starts from a shell with nothing of the last
    /// one's in it: no journal, no shelf, no half-pushed stack.
    @State private var generation = 0

    init(environment: Result<AteEnvironment, Error>) {
        self.environment = environment
        _services = State(initialValue: (try? environment.get()).map { AteServices(environment: $0) })
    }

    var body: some View {
        resolved
            // Settings' Appearance, applied to the window so Welcome, every sheet and every cover
            // follow it too — not just the views under one modifier.
            .ateAppearance(AtePreferences.standard.appearance)
    }

    @ViewBuilder
    private var resolved: some View {
        switch environment {
        case .success:
            if let services {
                V2Root(services: services, onSessionEnded: { generation += 1 })
                    .id(generation)
            }
        case .failure(let error):
            ConfigurationErrorView(error: error)
        }
    }
}

/// The one screen that exists so a broken checkout says what is missing instead of crashing.
struct ConfigurationErrorView: View {
    let error: any Error

    /// `gap:24px` between the line and the detail.
    private static let gap: CGFloat = 24

    var body: some View {
        VStack(spacing: Self.gap) {
            AteTitle(text: "Nothing\nto talk to.", style: .screenTitle)
            Text(String(describing: error))
                .ateText(.meta)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ateGround()
    }
}

#if DEBUG
#Preview("Staging") {
    AteRootView(environment: .success(AteEnvironment(
        name: .staging,
        supabaseURL: URL(string: "https://cvoitgoaosofkougmarn.supabase.co")!,
        supabaseKey: "sb_publishable_preview"
    )))
}

#Preview("Misconfigured") {
    AteRootView(environment: .failure(AteEnvironment.ConfigurationError.missing(key: "SUPABASE_URL")))
}
#endif
