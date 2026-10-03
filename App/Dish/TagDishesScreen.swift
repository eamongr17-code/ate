import AteKit
import SwiftUI

/// **One tag's dishes** (round 7) — what a dish page's "More to explore" chip opens: the tag's name in
/// the top bar, and every dish carrying it, best first, keyset-paged.
///
/// Not drawn on the canvas, so built from the vocabulary it already has: a pushed page's name beside
/// the glass back disc (`AteNavigationTitle`, like "From your photos"), and Search's own dish row —
/// cover, dish, place, score — on the list gutter, so a dish found by its tag and a dish found by
/// searching are the same row. Loading is that row's skeleton; nothing to show is one line.
struct TagDishesScreen: View {
    let onDish: (UUID) -> Void
    let analytics: AnalyticsRecorder

    /// Owned, not handed in: a navigation destination's body is re-evaluated whenever the shell
    /// around it changes, and a store built in that expression would reset the list every time.
    @State private var store: TagDishesStore
    @State private var hasRecordedView = false

    init(
        tag: DishTagRoute,
        reads: any DishExploreReading,
        analytics: @escaping AnalyticsRecorder,
        onDish: @escaping (UUID) -> Void
    ) {
        self.onDish = onDish
        self.analytics = analytics
        _store = State(initialValue: TagDishesStore(tag: tag, reads: reads))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch store.phase {
                case .loading:
                    SearchRowsSkeleton(height: DishResultRow.height, hasThumbnail: true, count: 6)
                        .transition(.opacity)
                case .empty:
                    LegacyEmptyState(title: "Nothing here\nyet.")
                        .ateEmptyPlacement(top: Self.listTop)
                case .failed(let message):
                    LegacyEmptyState(title: message)
                        .ateEmptyPlacement(top: Self.listTop)
                case .ready:
                    rows
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.phase)
            .padding(.horizontal, AteMetrics.listGutter)
            .padding(.top, AteMetrics.snug)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .ateNavigationBar(leading: { AteNavigationTitle(title: store.tag.label) })
        .refreshable { await store.refresh() }
        .task {
            await store.loadIfNeeded()
            guard hasRecordedView == false else { return }
            hasRecordedView = true
            analytics(DetailEvents.tagDishesViewed(kind: store.tag.kind))
        }
        .accessibilityIdentifier("tag.page")
    }

    /// Where the list begins: the 60 content top, the 44 back disc, the list's 8.
    private static let listTop: CGFloat = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.snug

    @ViewBuilder
    private var rows: some View {
        // Letter tiles chosen down the whole list, so no two neighbours match (round 4).
        let letters = DishLetter.neighbourly(store.dishes.map { ($0.dishID, $0.name) })
        ForEach(Array(store.dishes.enumerated()), id: \.element.id) { index, dish in
            DishResultRow(dish: DishResult(dish), letter: letters[index]) {
                DishPreviews.shared.note(DishPreview(dish))
                onDish(dish.dishID)
            }
            .task { await store.loadMoreIfNeeded(after: dish) }
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.regular)
        }
    }
}

extension DishResult {
    /// A tag's dish, as Search's dish row takes it.
    init(_ dish: SimilarDish) {
        self.init(
            dishID: dish.dishID,
            name: dish.name,
            restaurantID: dish.restaurantID,
            restaurantName: dish.restaurantName,
            score: dish.score,
            coverURLString: dish.coverURLString
        )
    }
}

extension DishPreview {
    /// What a "More like this" card or a tag's row printed — the aggregate included, because the row
    /// printed that very number (``DishPreview``'s rule).
    init(_ dish: SimilarDish) {
        self.init(
            dishID: dish.dishID,
            name: dish.name,
            restaurantID: dish.restaurantID,
            restaurantName: dish.restaurantName,
            score: dish.score,
            photoURL: dish.coverURLString
        )
    }
}

extension TagDishesScreen {
    /// One tag's dishes, opened from a dish page's chip (round 7).
    init(tag: DishTagRoute, context: RouteContext) {
        self.init(
            tag: tag,
            reads: context.services.dishExplore,
            analytics: context.services.analytics,
            onDish: { context.open(.dish($0), from: .tag) }
        )
    }
}
