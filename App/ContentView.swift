import AteKit
import SwiftUI

/// The app's root. Resolves the environment into either the tab scaffold or a loud, readable
/// configuration error — a misconfigured checkout must explain itself, not crash.
struct ContentView: View {
    let environment: Result<AteEnvironment, Error>

    var body: some View {
        switch environment {
        case .success(let environment):
            RootTabView(environment: environment)
        case .failure(let error):
            ConfigurationErrorView(error: error)
        }
    }
}

/// The tab scaffold: stock `TabView`, stock `Tab`s, native iOS 26 chrome (including the separated
/// search tab role) — no hand-built bar, no custom glass.
///
/// **Feed** and **Search** are real; Diary is still a placeholder and the `+` tab presents the Log
/// stand-in until that build lands.
///
/// One ``AteAPIClient`` is built here and handed to everything — feed, search and both detail
/// screens share a client, and therefore one URLSession and one auth session. A second client would
/// mean the Debug sign-in reached only half the app.
@MainActor
private struct RootTabView: View {
    private enum RootTab: Hashable {
        case feed, diary, log, search
    }

    private let environment: AteEnvironment
    private let feedStore: FeedStore
    private let searchServices: SearchServices
    private let detail: DetailContext
    private let debugSignIn: DebugStagingSignIn?

    @State private var selection: RootTab = .feed
    @State private var isLoggingPresented = false

    init(environment: AteEnvironment) {
        self.environment = environment
        let api = AteAPIClient(environment: environment)
        self.feedStore = FeedStore(
            client: GlobalFeedClient(api: api),
            analytics: TelemetryDeckFeedAnalytics()
        )
        self.searchServices = .live(api: api)
        // `onLogDish` stays nil: the Log sheet doesn't exist yet, so both detail screens hide their
        // CTA rather than showing a button that does nothing. One argument wires it later.
        self.detail = .live(api: api)
        self.debugSignIn = DebugStagingSignIn.make(for: environment, api: api)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Feed", systemImage: "fork.knife", value: RootTab.feed) {
                FeedView(store: feedStore, detail: detail, debugSignIn: debugSignIn)
            }

            Tab("Diary", systemImage: "book.closed", value: RootTab.diary) {
                PlaceholderTab(
                    title: "Diary",
                    systemImage: "book.closed",
                    message: "Everything you've logged, newest first.",
                    footnote: BuildStamp(environment: environment.name)
                        .summary(supabaseHost: environment.supabaseURL.host())
                )
            }

            // A tab item that *presents* rather than switches — the standard shape for a compose
            // action that lives in the tab bar. Content is never shown; the selection change is
            // bounced back and a sheet takes over.
            Tab("Log", systemImage: "plus.circle.fill", value: RootTab.log) {
                Color.clear
            }

            Tab(value: RootTab.search, role: .search) {
                SearchView(services: searchServices, detail: detail)
            }
        }
        .onChange(of: selection) { previous, new in
            guard new == .log else { return }
            selection = previous
            isLoggingPresented = true
        }
        .sheet(isPresented: $isLoggingPresented) {
            LogPlaceholderSheet()
        }
    }
}

/// Stand-in tab root. Replaced wholesale by each feature's real root at merge.
private struct PlaceholderTab: View {
    let title: String
    let systemImage: String
    let message: String
    var footnote: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.regular) {
                ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
                if let footnote {
                    Text(footnote)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .padding(.bottom, Theme.Spacing.loose)
                }
            }
            .navigationTitle(title)
        }
    }
}

/// Stand-in for the Log flow's sheet, so the `+` tab item is a real, dismissible interaction now.
private struct LogPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Log a dish",
                systemImage: "plus.circle",
                description: Text("Rate what you just ate. Arriving with the log build.")
            )
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The one screen that exists so a broken checkout says what's missing instead of crashing.
private struct ConfigurationErrorView: View {
    let error: any Error

    var body: some View {
        ContentUnavailableView {
            Label("Configuration problem", systemImage: "exclamationmark.triangle")
        } description: {
            Text(String(describing: error))
        }
        .background(Theme.Color.background)
    }
}

#Preview("Staging") {
    ContentView(environment: .success(AteEnvironment(
        name: .staging,
        supabaseURL: URL(string: "https://cvoitgoaosofkougmarn.supabase.co")!,
        supabaseKey: "sb_publishable_preview"
    )))
}

#Preview("Misconfigured") {
    ContentView(environment: .failure(AteEnvironment.ConfigurationError.missing(key: "SUPABASE_URL")))
}
