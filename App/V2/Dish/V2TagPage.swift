import AteKit
import SwiftUI

/// **A category's page, as an edition** (`design/rebuild/discover.html`, approved 4 Oct) — reached from
/// a Feed shelf's chevron, What you follow, or a dish page's More to explore. The category is the
/// page's own large title with its city on the baseline, folding into the bar on scroll; a glass
/// Follow / Following sits top right. The best dish in the city owns the top as the hero (no numeral),
/// 2 to 8 follow as ranked rows (and "See all" past eight opens the plain ranked list), then Places
/// known for it, New in <category>, the latest receipts with it on them (five at most), and the end.
///
/// A route's `.ranked` page is that plain list (``V2TagRankedPage``).
struct V2TagPage: View {
    let tag: DishTagRoute
    let context: V2PageContext

    var body: some View {
        switch tag.page {
        case .edition: V2TagEditionPage(tag: tag, context: context)
        case .ranked: V2TagRankedPage(tag: tag, context: context)
        }
    }
}

struct V2TagEditionPage: View {
    let tag: DishTagRoute
    let context: V2PageContext

    /// Owned, not handed in: a destination's body is re-evaluated whenever the shell around it
    /// changes, and a store built in that expression would reset the page every time.
    @State private var store: TagEditionStore
    @State private var isCollapsed = false
    @State private var hasRecordedView = false

    init(tag: DishTagRoute, context: V2PageContext) {
        self.tag = tag
        self.context = context
        let services = context.services
        _store = State(initialValue: TagEditionStore(
            tag: tag,
            reads: services.feedEdition,
            isSignedIn: { services.hasSession },
            analytics: services.analytics,
            savedDishes: services.savedDishes
        ))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                AtePageTitle(title: tag.label, subtitle: store.cityTitle)
                switch store.phase {
                case .loading:
                    loading
                case .empty:
                    AteEmptyState(line: V2TagCopy.empty)
                        .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
                        .accessibilityIdentifier("state.empty")
                case .failed(let message):
                    AteEmptyState(line: message, pill: (title: "Try again", action: retry))
                        .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
                        .accessibilityIdentifier("state.unreachable")
                case .ready:
                    V2TagEditionSections(store: store, actions: actions)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.phase)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .atePageCollapse($isCollapsed)
        .ateGround()
        .ateCollapsingTitle(tag.label, subtitle: store.cityTitle, isCollapsed: isCollapsed)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AteGlassLabelToggle(
                    offTitle: V2TagCopy.follow,
                    onTitle: V2TagCopy.following,
                    offIcon: .compose,
                    onIcon: .check,
                    isOn: store.isFollowing,
                    identifier: "tag.follow",
                    action: toggleFollow
                )
            }
        }
        .refreshable { await store.refresh() }
        .task {
            await store.loadIfNeeded()
            guard hasRecordedView == false else { return }
            hasRecordedView = true
            context.services.analytics(DetailEvents.tagDishesViewed(kind: tag.kind))
        }
        .accessibilityIdentifier("tag.page")
    }

    /// The hero and the ranked rows' skeletons, as The Top Ate loads.
    private var loading: some View {
        VStack(spacing: 0) {
            AteSkeleton(kind: .hero)
                .padding(.bottom, AteMetrics.tight)
            ForEach(2...TagEdition.rankedCount, id: \.self) { _ in
                AteSkeleton(kind: .rankedRow)
            }
        }
        .padding(.horizontal, AteMetrics.loose)
        .transition(.opacity)
    }

    /// The Feed's own rows, pushing on this tab, saving from the category page.
    private var actions: FeedEditionActions {
        FeedEditionActions(
            push: { context.open($0, from: .tag) },
            save: { dish, _ in save(dish) },
            saveFromSlip: saveFromSlip(_:dish:),
            act: { _ in }
        )
    }

    /// Signed out, the gate asks for sign-in and nothing flips.
    private func toggleFollow() {
        guard context.gate.permitsWrite(.follow) else { return }
        Task { await store.toggleFollow() }
    }

    private func save(_ dish: FeedDish) {
        let saves = context.saves
        Task { _ = await saves.toggle(dishID: dish.dishID, entryID: nil, isSaved: dish.isSaved, source: .tag) }
    }

    private func saveFromSlip(_ entry: EntryCard, dish: AteSlip.Dish) {
        let saves = context.saves
        Task { _ = await saves.toggle(dishID: dish.dishID, entryID: entry.id, isSaved: dish.isSaved, source: .tag) }
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

/// The page's sections once its dishes are read. "New in" and the receipts are absent when their read
/// failed or answered nothing.
struct V2TagEditionSections: View {
    let store: TagEditionStore
    let actions: FeedEditionActions

    var body: some View {
        FeedTopAte(lines: store.top.enumerated().map { TopAteLine(rank: $0.offset + 1, dish: $0.element) },
                   actions: actions)
        if store.hasMore {
            AteEndLinkRow(title: V2TagCopy.seeAll, identifier: "tag.seeAll") {
                actions.push(.tag(store.tag.ranked))
            }
        }
        let places = store.places
        if places.isEmpty == false {
            AteSectionHeading(title: V2TagCopy.places, identifier: "tag.section.places")
            V2TagPlacesShelf(places: places, actions: actions)
        }
        if store.newDishes.isEmpty == false {
            AteSectionHeading(title: store.newTitle, identifier: "tag.section.new")
            FeedNewRows(rows: store.newDishes, actions: actions)
        }
        if store.receipts.isEmpty == false {
            AteSectionHeading(title: FeedEditionCopy.latest, identifier: "tag.section.latest")
            ForEach(store.receipts) { entry in
                V2TagSlip(entry: entry, actions: actions)
                    .padding(.top, entry.id == store.receipts.first?.id ? 0 : AteMetrics.slipGap)
            }
        }
        AteEndRule(line: "You're caught up")
            .accessibilityIdentifier("tag.caughtUp")
    }
}

/// Places known for it: one shelf card per place, its best dish in the category as the picture and
/// the line under the place's name; the card opens the place, the bookmark saves the dish.
struct V2TagPlacesShelf: View {
    let places: [TagPlace]
    let actions: FeedEditionActions

    var body: some View {
        let tiles = DishLetter.neighbourly(places.map { ($0.dish.dishID, $0.dish.name) })
        let letters = Dictionary(zip(places.map(\.id), tiles), uniquingKeysWith: { first, _ in first })
        AteShelf(items: places) { place in
            let dish = place.dish
            AteShelfCard(
                photo: letters[place.id].map { AtePhoto.dish($0, cover: dish.coverURLString) }
                    ?? AtePhoto.dish(dish.dishID, name: dish.name, cover: dish.coverURLString),
                name: place.restaurantName,
                place: dish.name,
                score: dish.score.map(AteScore.average),
                isSaved: dish.isSaved,
                onOpen: { actions.push(.place(place.restaurantID)) },
                onSave: { actions.save(dish, .cravingShelf) }
            )
        }
        .accessibilityIdentifier("tag.places")
    }
}

/// A latest receipt on the category page: the approved slip on the Feed's surface.
struct V2TagSlip: View {
    let entry: EntryCard
    let actions: FeedEditionActions

    var body: some View {
        AteEntrySlip(
            slip: EntrySlipPresentation.feed(entry),
            surface: .feed,
            onOpen: { actions.push(.entry(EntryRoute(entry))) },
            onProfile: { actions.push(.profile(entry.authorID)) },
            onSave: { actions.saveFromSlip(entry, $0) },
            onPlace: { actions.push(.place($0)) },
            onDish: { actions.push(.dish($0.dishID)) },
            identifier: "tag.slip"
        )
        .ateCardWidth()
    }
}

enum V2TagCopy {
    static let follow = "Follow"
    static let following = "Following"
    static let seeAll = "See all"
    static let places = "Places known for it"
    static let empty = "Nothing here\nyet."
}
