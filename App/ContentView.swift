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
/// Tab order is the product's claim about itself (PRODUCT.md, "Journal-first"): **Diary → Log (+) →
/// Feed → Search**. Your own record is what the app opens on, every launch — selection always starts
/// at `.diary` and no last tab is persisted, because a journal you land in is a different product
/// from a feed you land in. Search stays last in code and iOS separates it out by its `.search` role.
///
/// Every tab is real except `+`, which presents the Log sheet rather than switching.
///
/// One ``AteAPIClient`` is built here and handed to everything — feed, diary, search and both detail
/// screens share a client, and therefore one URLSession and one auth session. A second client would
/// mean the Debug sign-in reached only half the app.
@MainActor
private struct RootTabView: View {
    private enum RootTab: Hashable {
        case feed, diary, log, search
    }

    private let environment: AteEnvironment
    private let feedStore: FeedStore
    private let diaryStore: DiaryStore
    private let searchServices: SearchServices
    private let detail: DetailContext
    private let logServices: LogServices
    private let debugSignIn: DebugStagingSignIn?

    @State private var selection: RootTab = .diary
    @State private var isLoggingPresented = false
    /// The Diary's navigation stack, hoisted out of ``DiaryView`` so finishing a log can put you
    /// back on the diary *at its root* rather than under whatever you were reading before (§7).
    @State private var diaryPath = NavigationPath()
    /// Incremented when the already-selected Diary tab is tapped again; the view scrolls to top.
    @State private var diaryScrollToTopSignal = 0

    init(environment: AteEnvironment) {
        self.environment = environment
        let api = AteAPIClient(environment: environment)
        self.feedStore = FeedStore(
            client: GlobalFeedClient(api: api),
            analytics: TelemetryDeckFeedAnalytics()
        )
        self.diaryStore = DiaryStore(client: DiaryClient(api: api), analytics: DetailTelemetry.live)
        self.searchServices = .live(api: api)
        // `onLogDish` stays nil for now: `DetailContext`'s closure carries no dish payload, so it
        // can't open the sheet pre-resolved (§1.1) — wiring a payloadless button would break the
        // entry contract. Follow-up: give the closure a dish, then wire it.
        self.detail = .live(api: api)
        self.logServices = .live(api: api)
        self.debugSignIn = DebugStagingSignIn.make(for: environment, api: api)
    }

    /// Which backend this build talks to, shown in Diary's bar. Debug only — a Release build must
    /// never display it, and this is the one place that decides that.
    private var environmentFootnote: String? {
        #if DEBUG
        BuildStamp(environment: environment.name).summary(supabaseHost: environment.supabaseURL.host())
        #else
        nil
        #endif
    }

    /// Selection goes through a hand-written binding because a tab bar's most-used gesture — tapping
    /// the tab you are already on — changes nothing and so never reaches `onChange`. The setter is
    /// where "tap Diary again to go to the top" can be heard at all.
    private var tabSelection: Binding<RootTab> {
        Binding(
            get: { selection },
            set: { tapped in
                guard tapped == selection else {
                    selection = tapped
                    return
                }
                if tapped == .diary { diaryScrollToTopSignal += 1 }
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Diary", systemImage: "book.closed", value: RootTab.diary) {
                DiaryView(
                    store: diaryStore,
                    path: $diaryPath,
                    detail: detail,
                    scrollToTopSignal: diaryScrollToTopSignal,
                    onLogDish: { isLoggingPresented = true },
                    debugSignIn: debugSignIn,
                    environmentFootnote: environmentFootnote
                )
            }

            // A tab item that *presents* rather than switches — the standard shape for a compose
            // action that lives in the tab bar. Content is never shown; the selection change is
            // bounced back and a sheet takes over.
            Tab("Log", systemImage: "plus.circle.fill", value: RootTab.log) {
                Color.clear
            }

            Tab("Feed", systemImage: "fork.knife", value: RootTab.feed) {
                FeedView(store: feedStore, detail: detail, debugSignIn: debugSignIn)
            }

            Tab(value: RootTab.search, role: .search) {
                SearchView(services: searchServices, detail: detail)
            }
        }
        .onChange(of: selection) { previous, new in
            guard new == .log else { return }
            selection = previous
            // The tab bar's `+` is an entry point like any other, and until now the only one that
            // reported nothing — which reads as zero rather than as unmeasured.
            detail.analytics(DetailEvents.logCTATapped(from: .tabBar))
            isLoggingPresented = true
        }
        .task { await autoSignInIfRequested() }
        // §6.4: a sitting whose post failed is retried once on the next foreground — the person was
        // told their dishes were saved, and this is what makes that true.
        .pendingLogPostRetry(services: logServices) { _ in
            Task { await feedStore.refresh() }
            diaryStore.reviewsWerePosted()
        }
        .sheet(isPresented: $isLoggingPresented) {
            LogSheet(
                entry: .tab,
                services: logServices,
                onFinished: { _ in
                    // The optimistic-insert seam doesn't exist yet; a refresh puts the new post at
                    // the top of the feed before the sheet is gone.
                    Task { await feedStore.refresh() }
                    // The diary reloads when it's next looked at, rather than fetching behind a
                    // sheet for a tab that may not be visited — but it *will* contain the post.
                    diaryStore.reviewsWerePosted()
                    // …and it is looked at immediately: Done on the receipt lands you on your own
                    // record, at the top, with whatever you were reading before the log unwound.
                    landOnDiaryRoot()
                }
            )
        }
    }
}

private extension RootTabView {
    /// Where a finished log ends: the Diary tab, its stack unwound, its list at the top — so the
    /// dish you just rated is the first thing on screen and the record is visibly yours (§7).
    @MainActor
    func landOnDiaryRoot() {
        selection = .diary
        diaryPath = NavigationPath()
        diaryScrollToTopSignal += 1
    }

    /// The Debug/Beta staging auto sign-in (`-ate-debug-signin`), run at the *scaffold* rather than
    /// on any one tab: the launch tab is the Diary, so hanging this off the feed's `.task` (where it
    /// used to live) left every staging drive signed out.
    ///
    /// The launch tab has already asked for its page by the time a session exists, and that read
    /// failed with `signedOut` — so the diary is invalidated and asked again. Nothing here fetches
    /// the feed: it loads when it is visited.
    @MainActor
    func autoSignInIfRequested() async {
        guard let debugSignIn, debugSignIn.isAutoSignInRequested else { return }
        await debugSignIn.signIn()
        diaryStore.invalidate()
        await diaryStore.loadIfNeeded()
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
