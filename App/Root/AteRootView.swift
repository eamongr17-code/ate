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

/// **The shell**: the four tabs, the floating bar, the `+` that presents the composer, and the one
/// navigation stack the core loop travels on.
///
/// Journal is home (PRODUCT.md decision 1) and selection always starts there — no last tab is
/// persisted, because a journal you land in is a different product from a feed you land in.
@MainActor
private struct AteShell: View {
    let services: AteServices

    @State private var tab: AteTab = .journal
    @State private var journal: JournalStore
    /// Non-nil presents the composer, and carries what it was opened with.
    @State private var composing: ComposerPresentation?
    /// The Journal tab's stack. Hoisted here so Done in the composer can land on the new entry, at
    /// the journal's root, rather than under whatever was open before.
    @State private var path: [EntryRoute] = []
    /// Bumped when a tab's own item is tapped again — the screen scrolls to the top.
    @State private var scrollToTop = 0
    @State private var hasSession: Bool
    @State private var isSigningIn = false
    /// The signed-in person's handle. A receipt is signed, so it is loaded once at the shell rather
    /// than by whichever screen happens to need it first.
    @State private var handle: String?
    @Environment(\.scenePhase) private var scenePhase

    init(services: AteServices) {
        self.services = services
        _hasSession = State(initialValue: services.hasSession)
        _journal = State(initialValue: JournalStore(entries: services.entries))
        #if DEBUG
        ComposerDebugLaunch.seedDraftIfRequested(into: services.drafts)
        if ComposerDebugLaunch.opensComposer {
            _composing = State(initialValue: ComposerPresentation(origin: .tabBar))
        }
        #endif
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
        // An entry that could not be sent is still the person's. The outbox is worked on every
        // return to the app, and anything that lands refreshes the journal under it.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await drainOutbox() }
        }
    }

    private var shell: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                current
                AteTabScrim()
                AteTabBar(selection: selection, onCompose: { openComposer(.tabBar) })
            }
            .ignoresSafeArea(.keyboard)
            .ateGround()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: EntryRoute.self) { route in
                EntryScreen(route: route, services: services) { journal.replace($0) }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .fullScreenCover(item: $composing) { presentation in
            ComposerScreen(presentation: presentation, services: services, onSaved: landOnEntry)
        }
    }

    @ViewBuilder
    private var current: some View {
        switch tab {
        case .journal:
            JournalScreen(
                store: journal,
                scrollToTopSignal: scrollToTop,
                onCompose: { openComposer(.journalEmpty) },
                onOpen: { path.append(EntryRoute(entryID: $0.id)) }
            )
            #if DEBUG
            .task { await openNewestEntryIfRequested() }
            #endif
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

    private func openComposer(_ origin: ComposerPresentation.Origin) {
        composing = ComposerPresentation(origin: origin)
    }

    /// Done in the composer: the entry is already on the journal, and this is where the receipt
    /// prints. The stack is unwound first, so writing twice in a row does not stack entry pages.
    private func landOnEntry(_ card: EntryCard) {
        journal.insert(card)
        tab = .journal
        path = [EntryRoute(entryID: card.id, isFreshlyWritten: true)]
    }

    #if DEBUG
    /// `-ate-open-entry`: pushes the newest entry once the first page has landed. Waits for it
    /// rather than racing the journal's own load, which would find an empty list and give up.
    private func openNewestEntryIfRequested() async {
        guard ComposerDebugLaunch.opensEntry, path.isEmpty else { return }
        for _ in 0..<30 {
            await journal.loadIfNeeded()
            if let first = journal.entries.first {
                path = [EntryRoute(entryID: first.id, isFreshlyWritten: true)]
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #endif

    private func drainOutbox() async {
        let landed = await services.outbox.run()
        guard landed.isEmpty == false else { return }
        journal.invalidate()
        await journal.loadIfNeeded()
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
        journal.invalidate()
    }

    private func autoSignInIfRequested() async {
        guard hasSession == false, let debugSignIn = services.debugSignIn,
              debugSignIn.isAutoSignInRequested else { return }
        await signIn()
    }

    private func loadHandle() async {
        guard hasSession, handle == nil else { return }
        handle = await services.entries.currentHandle()
    }
}

/// The one screen that exists so a broken checkout says what is missing instead of crashing.
struct ConfigurationErrorView: View {
    let error: any Error

    var body: some View {
        AteEmptySlip(
            label: "Configuration",
            title: "Nothing\nto talk to.",
            prose: String(describing: error)
        )
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
