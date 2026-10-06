import AteKit
import SwiftUI

/// **The shell**: iOS 26's own `TabView` — Journal, Feed, Saved, You — with `+` as a tab in the
/// bar's detached trailing slot, the composer as a sheet over it, and four routers, one stack each.
///
/// - `+` takes the role the system draws as its own glass circle (``composeRole``). Its
///   selection is refused in the binding: the composer comes up and the selected tab never changes.
/// - The bar minimises on scroll down and comes back on scroll up (`.onScrollDown`), and it stays on
///   every pushed page — the system's own behaviour for a `NavigationStack` inside a `Tab`.
/// - The selected tab is the system's quiet state, drawn in ink: nothing in the bar is coloured.
struct TabShell: View {
    let app: AppModel

    @State private var selection: V2Tab
    @State private var journal: TabRouter<JournalStores>
    @State private var feed: TabRouter<V2FeedStores>
    @State private var saved: TabRouter<SavedStores>
    @State private var you: TabRouter<YouStores>

    init(app: AppModel, start: V2Launch.Start) {
        self.app = app
        _selection = State(initialValue: start.tab)
        // Each tab's stores are made the first time the tab is shown, from the services.
        let services = app.services
        _journal = State(initialValue: TabRouter(tab: .journal) { JournalStores(services: services) })
        _feed = State(initialValue: TabRouter(tab: .feed) { V2FeedStores(services: services) })
        _saved = State(initialValue: TabRouter(tab: .saved) { SavedStores(app: app) })
        _you = State(initialValue: TabRouter(tab: .you) { YouStores(services: services) })
        if start.composes { app.compose(ComposerPresentation(origin: .tabBar)) }
    }

    var body: some View {
        TabView(selection: selectionBinding) {
            Tab(value: V2Tab.journal) {
                stack(journal) { JournalRoot(router: journal, app: app) }
            } label: { label(.journal) }
            Tab(value: V2Tab.feed) {
                stack(feed) { FeedRoot(router: feed, app: app) }
            } label: { label(.feed) }
            Tab(value: V2Tab.saved) {
                stack(saved) { SavedRoot(router: saved, app: app) }
            } label: { label(.saved) }
            Tab(value: V2Tab.you) {
                stack(you) { YouRoot(router: you, app: app) }
            } label: { label(.you) }
            // `+`: never shown, never selected — the binding turns its tap into the composer.
            Tab(value: V2Tab.compose, role: Self.composeRole) {
                Color.clear
            } label: {
                Label {
                    Text(V2Tab.compose.title)
                } icon: {
                    V2Tab.compose.icon.barImage(size: AteNativeChromeMetrics.composeGlyph)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(AteNativeChrome.tint)
        // One full-screen photo viewer for every photo under the tabs — slips, entries, the dish
        // hero, the menu. Kit photo surfaces open it themselves.
        .atePhotoViewerHost()
        .sheet(isPresented: Bindable(app).isComposing) {
            ComposerSheet(app: app)
                .ateCoversThePage()
        }
        .ateLinkShell() // a waiting link is pushed once the tabs are up
        .onChange(of: app.linkedEntry, initial: true) { _, entryID in
            guard let entryID else { return }
            app.linkedEntry = nil
            openLinkedEntry(entryID)
        }
        .onChange(of: selection, initial: true) { _, tab in router(for: tab)?.shown() }
    }

    /// The role that puts `+` in the bar's detached trailing slot. iOS 26 gives that slot to the
    /// search tab; iOS 27 gives it to the new `.prominent` role and draws a search tab inside the bar.
    /// `.prominent` exists only in the iOS 27 SDK; the TestFlight lane builds with Xcode 26, where
    /// the search role keeps the slot on both OS versions, so the SDK decides at compile time.
    private static var composeRole: TabRole {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { .prominent } else { .search }
        #else
        .search
        #endif
    }

    // MARK: - Selection

    /// A hand-written binding: `+` is refused here (it presents and leaves the selection where it
    /// was), and a tap on the tab already selected — which changes nothing and never reaches
    /// `onChange` — is heard here as a re-tap.
    private var selectionBinding: Binding<V2Tab> {
        Binding(
            get: { selection },
            set: { tapped in
                if tapped == .compose {
                    openComposer()
                } else if tapped == selection {
                    router(for: tapped)?.reselected()
                } else if mayOpen(tapped) {
                    selection = tapped
                    app.services.analytics(ShellEvents.tabSelected(tapped.rawValue))
                }
            }
        )
    }

    private func openComposer() {
        guard app.gate.permitsWrite(.compose) else { return }
        AteHaptics.key()
        app.services.analytics(ShellEvents.composeOpened(over: selection.rawValue))
        app.compose(ComposerPresentation(origin: .tabBar))
    }

    /// Journal, Saved and You are yours. A browser tapping one is asked to sign in, and stays put.
    private func mayOpen(_ tab: V2Tab) -> Bool {
        switch tab {
        case .journal: app.gate.permitsWrite(.journal)
        case .saved: app.gate.permitsWrite(.save)
        case .you: app.gate.permitsWrite(.you)
        case .feed, .compose: true
        }
    }

    private func router(for tab: V2Tab) -> (any V2TabRouting)? {
        switch tab {
        case .journal: journal
        case .feed: feed
        case .saved: saved
        case .you: you
        case .compose: nil
        }
    }

    // MARK: - Stacks

    private func label(_ tab: V2Tab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            tab.icon.barImage()
        }
    }

    /// One tab's stack. Every page the app pushes is declared once, here (``V2Destinations``).
    private func stack<Stores, Root: View>(
        _ router: TabRouter<Stores>,
        @ViewBuilder root: () -> Root
    ) -> some View {
        NavigationStack(path: Bindable(router).path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    V2Destinations(route: route, context: V2PageContext(
                        app: app,
                        tab: router.tab,
                        source: router.sources[route] ?? .unknown,
                        push: { router.open($0, from: $1) }
                    ))
                }
        }
    }

    /// A link's entry, pushed on the current tab — on the Feed for somebody reading signed out, since
    /// Journal, Saved and You are a signed-in person's own.
    private func openLinkedEntry(_ entryID: UUID) {
        if app.gate.isBrowsing, [.journal, .saved, .you].contains(selection) {
            selection = .feed
        }
        guard let router = router(for: selection), router.path.last?.entryID != entryID else { return }
        router.open(.entry(EntryRoute(entryID: entryID)), from: .link)
        app.services.analytics(LinkEvents.linkOpened(.entry(entryID)))
    }
}
