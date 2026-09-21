import AteKit
import SwiftUI

/// **The app's root.** Resolves the build's environment into either the shell or a loud, readable
/// configuration error — a misconfigured checkout must explain itself, not crash.
struct AteRootView: View {
    let environment: Result<AteEnvironment, Error>

    var body: some View {
        #if DEBUG || BETA
        // The gallery has no backend at all, so it must not be reachable only through a screen that
        // needs one: `-ate-design-gallery` opens it straight from launch, which is also how it gets
        // driven on a simulator. Otherwise it presents from the ROOT (a `fullScreenCover` hung off a
        // menu's content is not a reliable presentation context).
        if ProcessInfo.processInfo.arguments.contains("-ate-design-gallery") {
            DesignSystemGallery()
        } else {
            resolved.designSystemGalleryPresenter()
        }
        #else
        resolved
        #endif
    }

    @ViewBuilder
    private var resolved: some View {
        switch environment {
        case .success(let environment):
            AteShell(services: AteServices(environment: environment))
        case .failure(let error):
            ConfigurationErrorView(error: error)
        }
    }
}

/// **The shell**: the four tabs, the floating bar, and the `+` that presents the composer.
///
/// Journal is home (PRODUCT.md decision 1) and selection always starts there — no last tab is
/// persisted, because a journal you land in is a different product from a feed you land in.
@MainActor
private struct AteShell: View {
    let services: AteServices

    @State private var tab: AteTab = .journal
    /// Non-nil presents the composer, and carries the draft it opens on. One piece of state, so a
    /// door can never present without the thing it was opened with.
    @State private var composing: ComposerPresentation?
    /// Bumped when a tab's own tab item is tapped again — the screen scrolls to the top.
    @State private var scrollToTop = 0
    @State private var hasSession: Bool
    @State private var isSigningIn = false
    /// The signed-in person's handle. A receipt is signed, so this is loaded once at the shell rather
    /// than by whichever screen happens to need it first.
    @State private var handle: String?

    init(services: AteServices) {
        self.services = services
        _hasSession = State(initialValue: services.hasSession)
    }

    var body: some View {
        Group {
            if hasSession {
                shell
                    .task(id: hasSession) { await loadHandle() }
            } else {
                WelcomeScreen(
                    canSignIn: services.debugSignIn != nil,
                    isBusy: isSigningIn,
                    onSignIn: signIn
                )
            }
        }
        .task { await autoSignInIfRequested() }
    }

    private var shell: some View {
        ZStack(alignment: .bottom) {
            current
            AteTabScrim()
            AteTabBar(selection: selection, onCompose: openComposer)
        }
        .ignoresSafeArea(.keyboard)
        .ateGround()
        .fullScreenCover(item: $composing) { presentation in
            ComposerScreen(presentation: presentation, services: services)
        }
    }

    @ViewBuilder
    private var current: some View {
        switch tab {
        case .journal:
            JournalScreen(services: services, scrollToTopSignal: scrollToTop, onCompose: openComposer)
        case .feed:
            FeedScreen()
        case .search:
            SearchScreen()
        case .you:
            YouScreen(handle: handle)
        }
    }

    /// A hand-written binding because a tab bar's most-used gesture — tapping the tab you are already
    /// on — changes nothing and so never reaches `onChange`. The setter is where it can be heard.
    private var selection: Binding<AteTab> {
        Binding(
            get: { tab },
            set: { tapped in
                guard tapped == tab else {
                    tab = tapped
                    return
                }
                scrollToTop += 1
            }
        )
    }

    private func openComposer() {
        composing = ComposerPresentation(origin: .tabBar)
    }

    // MARK: - Session

    /// Sign in with Apple is milestone 2. Until then the one path in is the seeded staging demo
    /// account, which exists in Debug and Beta only (`DebugStagingSignIn`).
    private func signIn() async {
        guard let debugSignIn = services.debugSignIn else { return }
        isSigningIn = true
        await debugSignIn.signIn()
        isSigningIn = false
        hasSession = services.hasSession
    }

    private func autoSignInIfRequested() async {
        guard hasSession == false, let debugSignIn = services.debugSignIn,
              debugSignIn.isAutoSignInRequested else { return }
        await signIn()
    }

    private func loadHandle() async {
        guard hasSession, handle == nil else { return }
        handle = try? await ViewerProfileClient(api: services.api).viewer().username
    }
}

/// The one screen that exists so a broken checkout says what is missing instead of crashing.
struct ConfigurationErrorView: View {
    let error: any Error

    var body: some View {
        VStack(spacing: AteMetrics.loose) {
            AteEmptySlip(
                label: "Configuration",
                title: "Nothing\nto talk to.",
                prose: String(describing: error)
            )
        }
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
