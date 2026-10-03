import AteKit
import SwiftUI

/// **One dish: its aggregate, and everything anybody has said about it.** Glass back left, the
/// glass bookmark right — Save is the only action. Then the tilted hero, the name and its place, the
/// aggregate (one decimal, stars to the nearest half), each review as who and how much with no words
/// (round 4), and under them More to explore and More like this (round 7).
///
/// Opened from a row that knew the dish (round 6), the page draws from it at once and fills in
/// place; opened by id alone, it waits as still shapes and fades in once. The bookmark is the one
/// ``SaveAction``: a dish saved here is saved on every page underneath it.
struct V2DishPage: View {
    let dishID: UUID
    let context: V2PageContext

    @State private var store: DishPageStore
    /// Signed-in reads (round 7): a browser with no session never holds their space open.
    @State private var explore: DishExploreStore?
    @State private var isCollapsed = false
    @State private var titleBottom: CGFloat = 0

    init(dishID: UUID, context: V2PageContext) {
        self.dishID = dishID
        self.context = context
        let services = context.services
        _explore = State(initialValue: context.app.hasSession
            ? DishExploreStore(dishID: dishID, reads: services.dishExplore)
            : nil)
        _store = State(initialValue: DishPageStore(
            dishID: dishID,
            source: context.source,
            dishes: services.dishPages,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions,
            previews: DishPreviews.shared,
            analytics: services.analytics
        ))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .ateAnimation(AteMotion.fillIn, value: store.isSettled)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.section)
            .coordinateSpace(.named(BrowsePage.content))
        }
        .scrollIndicators(.hidden)
        .browseCollapse($isCollapsed, after: titleBottom)
        .ateGround()
        .browseBarTitle(store.summary?.name ?? store.preview?.name, isShown: isCollapsed)
        .toolbar {
            if let summary = store.summary {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save(summary) } label: {
                        (store.isSaved ? AteIcon.saved : AteIcon.save).view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel(store.isSaved ? "Saved \(summary.name)" : "Save \(summary.name)")
                    .accessibilityAddTraits(store.isSaved ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("dish.save")
                }
            }
        }
        .refreshable {
            await store.refresh()
            await explore?.refresh()
        }
        .task {
            await store.load()
            // After the page's own read, never beside it: the sections below the reviews must not
            // slow the part of the page somebody opened it for.
            guard store.summary != nil else { return }
            await explore?.load()
        }
        .atePhotoViewerHost()
        .accessibilityIdentifier("dish.page")
    }

    // MARK: - The page

    @ViewBuilder
    private var content: some View {
        if let preview = store.preview, store.isSettled == false || store.summary != nil {
            previewed(preview)
        } else {
            switch store.isSettled ? store.header : .loading {
            case .loading:
                VStack(alignment: .leading, spacing: AteMetrics.loose) {
                    AteDishHero.placeholder
                        .padding(.leading, V2DishMetrics.heroInset)
                    AteSkeletonBar(width: V2DishMetrics.nameBar, height: V2DishMetrics.nameBarHeight,
                                   palette: .automatic)
                        .ateBreathing()
                        .padding(.horizontal, AteMetrics.listGutter)
                    AteReviewRowSkeleton()
                        .padding(.horizontal, AteMetrics.listGutter)
                }
                .transition(.opacity)
            case .unavailable:
                AteEmptyState(line: "This dish\nisn't here.")
                    .browseFillsPage()
            case .unreachable:
                BrowsePage.unreachable { Task { await store.retry() } }
                    .browseFillsPage()
            case .ready(let summary):
                VStack(alignment: .leading, spacing: AteMetrics.loose) {
                    hero(store.heroPhotoURLs.map { AtePhoto.remote($0) })
                    title(name: summary.name, place: summary.restaurantName, placeID: summary.restaurantID)
                    aggregate(summary)
                }
                .transition(.opacity)
                reviews
                exploreSections
            }
        }
    }

    /// **Opened from a row that knew the dish**: one header, drawn at once from the preview and
    /// filled in place as the reads answer, so the name never re-draws. The reviews wait as still
    /// rows at their own size.
    @ViewBuilder
    private func previewed(_ preview: DishPreview) -> some View {
        let summary = store.isSettled ? store.summary : nil
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            if summary != nil {
                hero(store.heroPhotoURLs.map { AtePhoto.remote($0) })
            } else if let url = preview.photoURL {
                hero([AtePhoto.remote(url)], tappable: false)
            } else if preview.hasPhotos == true {
                AteDishHero.placeholder
                    .padding(.leading, V2DishMetrics.heroInset)
            }
            title(
                name: summary?.name ?? preview.name,
                place: summary?.restaurantName ?? preview.restaurantName,
                placeID: summary?.restaurantID ?? preview.restaurantID
            )
            if let summary {
                aggregate(summary)
            } else if let score = preview.score {
                AteDishAggregate(score: score, peopleCount: 0)
                    .padding(.horizontal, AteMetrics.listGutter)
            } else {
                AteSkeletonBar(width: V2DishMetrics.aggregateBar, height: V2DishMetrics.aggregateBarHeight,
                               palette: .automatic)
                    .ateBreathing()
                    .padding(.horizontal, AteMetrics.listGutter)
            }
        }
        if summary != nil {
            reviews
            exploreSections
        } else {
            AteReviewRowSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, AteMetrics.loose)
                .transition(.opacity)
        }
    }

    // MARK: - The header

    /// The tilted pair; a photo opens the viewer on it.
    private func hero(_ photos: [AtePhoto], tappable: Bool = true) -> some View {
        V2DishHeroPhotos(photos: photos, isTappable: tappable)
            .padding(.leading, V2DishMetrics.heroInset)
    }

    /// The dish, and the place under it as the door back to the menu it came off. Before the read, a
    /// place the opening row did not know is a still bar at the line's height.
    private func title(name: String, place: String?, placeID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            AteExactText(text: name, style: .entryPlace, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .browseTitleBottom($titleBottom)
            if let place {
                Button {
                    guard let placeID else { return }
                    PlacePreviews.shared.note(placeID, name: place)
                    context.open(.place(placeID), from: .dish)
                } label: {
                    HStack(spacing: AteMetrics.hairspace) {
                        Text(place).ateText(.rowTitle)
                        AteIcon.chevron.view(size: V2DishMetrics.chevron)
                    }
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(minHeight: AteMetrics.hit)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(placeID == nil)
                .accessibilityLabel(place)
                .accessibilityIdentifier("dish.place")
            } else {
                AteSkeletonBar(width: V2DishMetrics.placeBar, height: V2DishMetrics.placeBarHeight,
                               palette: .automatic)
                    .ateBreathing()
                    .frame(height: AteMetrics.hit)
            }
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    private func aggregate(_ summary: DishSummary) -> some View {
        AteDishAggregate(score: summary.score, peopleCount: summary.peopleCount, tags: summary.tags)
            .padding(.horizontal, AteMetrics.listGutter)
    }

    // MARK: - The reviews

    @ViewBuilder
    private var reviews: some View {
        switch store.phase {
        case .loading:
            AteReviewRowSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
                .padding(.top, AteMetrics.loose)
        case .empty:
            // Nobody has written about it yet. Honest, and not an instruction.
            AteEmptyState(line: "Nobody's written\nabout this yet.")
                .padding(.vertical, AteMetrics.section)
        case .signedOut:
            AteEmptyState(line: "Nobody's\nsigned in.")
                .padding(.vertical, AteMetrics.section)
        case .failed(let message):
            AteEmptyState(line: message)
                .padding(.vertical, AteMetrics.section)
        case .ready:
            reviewRows
        }
    }

    /// One row each of the page's lazy stack, You first, then everyone else newest first.
    @ViewBuilder
    private var reviewRows: some View {
        ForEach(store.reviews) { review in
            AteReviewRow(
                userID: review.author?.id ?? review.reviewID,
                name: Self.name(of: review),
                handle: review.author?.username ?? "?",
                rating: review.score,
                isFirst: review.id == store.reviews.first?.id,
                // Your own "You" is not a door: the You tab is your profile.
                onProfile: review.isMine ? nil : review.author.map { author in { openProfile(author.id) } },
                // A legacy review has no visit to open.
                onOpen: review.entryID.map { entryID in { openEntry(entryID) } }
            )
            .task { await store.loadMoreIfNeeded(after: review) }
            .padding(.top, review.id == store.reviews.first?.id ? AteMetrics.loose : 0)
            .padding(.horizontal, AteMetrics.listGutter)
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.regular)
                .padding(.horizontal, AteMetrics.listGutter)
        }
    }

    /// "You" for your own, the handle for everyone else's; an author who is blocked or gone loses
    /// their name, never their review.
    private static func name(of review: DishReview) -> String {
        if review.isMine { return "You" }
        guard let username = review.author?.username else { return "Someone" }
        return "@\(username)"
    }

    private func openEntry(_ entryID: UUID) {
        context.services.analytics(DetailEvents.dishReviewOpened(target: .entry))
        context.open(.entry(EntryRoute(entryID: entryID)), from: .dish)
    }

    private func openProfile(_ userID: UUID) {
        context.services.analytics(DetailEvents.dishReviewOpened(target: .profile))
        context.open(.profile(userID), from: .dish)
    }

    // MARK: - Under the reviews

    @ViewBuilder
    private var exploreSections: some View {
        if let explore, store.isSettled, store.summary != nil {
            V2DishExplore(store: explore, context: context)
                .transition(.opacity)
        }
    }

    // MARK: - Save

    private func save(_ summary: DishSummary) {
        Task {
            await context.saves.toggle(
                dishID: summary.dishID,
                // Made on the dish itself, not off somebody's visit: the provenance is nothing.
                entryID: nil,
                isSaved: store.isSaved,
                source: .dish
            )
        }
    }
}

/// The hero, under the page's photo viewer host — so it reads the viewer the host puts around it.
private struct V2DishHeroPhotos: View {
    let photos: [AtePhoto]
    let isTappable: Bool

    @Environment(\.atePhotoViewer) private var showPhotos

    var body: some View {
        AteDishHero(photos: photos, onTap: isTappable ? { showPhotos(photos, at: $0) } : nil)
    }
}

enum V2DishMetrics {
    /// The hero sits 2 past the gutter (the cluster insets its own 6 for the tilt).
    static let heroInset: CGFloat = AteMetrics.listGutter - AteDishHeroMetrics.inset + AteMetrics.hairspace
    static let chevron: CGFloat = 15
    static let nameBar: CGFloat = 240
    static let nameBarHeight: CGFloat = 36
    static let placeBar: CGFloat = 110
    static let placeBarHeight: CGFloat = 14
    static let aggregateBar: CGFloat = 160
    static let aggregateBarHeight: CGFloat = 52
}
