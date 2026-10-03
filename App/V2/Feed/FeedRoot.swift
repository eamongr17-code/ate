import AteKit
import SwiftUI

/// **The Feed tab's root** — the edition (`design/rebuild/feed.html`): a finite, dish-first page you
/// finish. The Top Ate, Because you loved…, New to the record, a shelf per craving, five latest
/// receipts, then the end.
///
/// The chrome is the system's: "Feed" with its city as the subtitle in the native bar, folding inline
/// on scroll, and one trailing glass group — the area as a native Menu (Near me, Everywhere, the
/// cities) and the cravings heart. It opens on your Journal's city; location is asked for only when
/// Near me is picked (``V2FeedStores``). Signed out, The Top Ate and the latest receipts are the page.
struct FeedRoot: View {
    let router: TabRouter<V2FeedStores>
    let app: AppModel

    @State private var isCollapsed = false
    @State private var isChoosingCravings = false
    @State private var acting: EntryCard?
    @State private var scrollToTopAfterArea = 0

    init(router: TabRouter<V2FeedStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    private var stores: V2FeedStores { router.stores }

    var body: some View {
        let stores = stores
        ScrollViewReader { reader in
            ScrollView {
                // The scroll view's content IS the lazy stack, and every section is one of its own
                // rows — never a lazy stack inside a `VStack` (the round-5 main-thread lock).
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(FeedRootAnchor.top)
                    FeedEditionSections(
                        edition: stores.edition,
                        latest: stores.latest,
                        isSignedIn: app.hasSession,
                        actions: actions,
                        onChooseCravings: { isChoosingCravings = true }
                    )
                }
                .padding(.bottom, AteMetrics.tabBarScrollInset)
            }
            .scrollIndicators(.hidden)
            .ateRootCollapse($isCollapsed)
            .refreshable { await refresh(stores) }
            .onChange(of: router.scrollToTop + scrollToTopAfterArea) { _, _ in
                withAnimation { reader.scrollTo(FeedRootAnchor.top, anchor: .top) }
            }
        }
        .accessibilityIdentifier("v2.root.feed")
        .ateGround()
        .ateRootToolbar(
            title: .text(V2Tab.feed.title),
            subtitle: subtitle,
            inline: AteInlineTitle(title: V2Tab.feed.title, subtitle: subtitle),
            isCollapsed: isCollapsed
        ) {
            AteGlassMenuItem(icon: .place, label: "Area") {
                FeedAreaMenu(area: stores.area) { pick in
                    Task { await choose(pick, in: stores) }
                }
            }
            .accessibilityIdentifier("feed.area")
            if app.hasSession {
                AteGlassItem(icon: .heart, label: "Cravings") { isChoosingCravings = true }
                    .accessibilityIdentifier("feed.cravings")
            }
        }
        .task {
            app.services.analytics(SocialEvents.feedViewed())
            stores.edition.beginVisit()
            async let sections: Void = stores.edition.loadIfNeeded()
            await stores.latest.loadIfNeeded()
            await sections
        }
        // Read ahead, so the area menu opens with its cities in it.
        .task { await stores.area.loadCitiesIfNeeded() }
        .sheet(isPresented: $isChoosingCravings) {
            FeedCravingsSheet(store: stores.edition) { next in
                Task { await stores.edition.saveCravings(next) }
            }
        }
        .sheet(item: $acting) { entry in
            FeedSlipActionsSheet(pressed: entry, latest: stores.latest, app: app) { authorID in
                stores.latest.removeAuthor(authorID)
            }
        }
    }

    /// The city under the title — nothing until the opening is settled, so a "Near me" it is about
    /// to take back never flashes; "Near me" once that is the pick.
    private var subtitle: String? {
        let area = stores.area
        guard area.hasOpened else { return nil }
        return area.location == .nearMe ? FeedAreaMenu.nearMeTitle : area.locationTitle
    }

    private var actions: FeedEditionActions {
        FeedEditionActions(
            push: { router.open($0, from: .feed) },
            save: save(_:from:),
            saveFromSlip: saveFromSlip(_:dish:),
            act: { acting = $0 }
        )
    }

    // MARK: - Where

    /// A pick from the area menu. Near me asks for the location — the only place the Feed does —
    /// and, refused, the Feed stays where it was. Near me picked again is a retry: the phone may
    /// have moved.
    private func choose(_ pick: FeedLocation, in stores: V2FeedStores) async {
        let area = stores.area
        if pick == .nearMe {
            guard let point = await stores.locator.current() else { return }
            area.choose(location: .nearMe)
            await area.resolveNearMe(latitude: point.latitude, longitude: point.longitude)
        } else {
            guard area.choose(location: pick) else { return }
        }
        scrollToTopAfterArea += 1
        async let sections: Void = stores.edition.reload()
        await stores.latest.reload()
        await sections
    }

    private func refresh(_ stores: V2FeedStores) async {
        async let cities: Void = stores.area.loadCities()
        async let sections: Void = stores.edition.refresh()
        await stores.latest.refresh()
        _ = await (cities, sections)
    }

    // MARK: - Save

    /// A dish anywhere on the page but a slip, and the section it was saved from.
    private func save(_ dish: FeedDish, from section: FeedEvents.Section) {
        let analytics = app.services.analytics
        let saves = app.saves
        Task {
            let went = await saves.toggle(dishID: dish.dishID, entryID: nil, isSaved: dish.isSaved, source: .feed)
            if went, dish.isSaved == false { analytics(FeedEvents.dishSaved(section)) }
        }
    }

    /// A latest receipt's dish row.
    private func saveFromSlip(_ entry: EntryCard, dish: AteSlip.Dish) {
        let saves = app.saves
        Task {
            _ = await saves.toggle(dishID: dish.dishID, entryID: entry.id, isSaved: dish.isSaved, source: .feed)
        }
    }
}

enum FeedRootAnchor {
    static let top = "feed.top"
}
