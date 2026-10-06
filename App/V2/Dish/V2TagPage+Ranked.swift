import AteKit
import SwiftUI

/// **One tag's dishes, all of them** — the plain ranked list a category page's "See all" opens past
/// its first eight (4 Oct; round 7's wall, now the secondary page): the tag's name and city in the
/// inline bar, and every dish carrying it, best first, keyset-paged, as the kit's dish rows — so a
/// dish found by its tag and a dish found by searching are the same row.
struct V2TagRankedPage: View {
    let tag: DishTagRoute
    let context: V2PageContext

    /// Owned, not handed in: a destination's body is re-evaluated whenever the shell around it
    /// changes, and a store built in that expression would reset the list every time.
    @State private var store: TagDishesStore
    @State private var hasRecordedView = false

    init(tag: DishTagRoute, context: V2PageContext) {
        self.tag = tag
        self.context = context
        _store = State(initialValue: TagDishesStore(tag: tag, reads: context.services.dishExplore))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch store.phase {
                case .loading:
                    ForEach(0..<V2TagMetrics.skeletonRows, id: \.self) { _ in
                        AteSkeleton(kind: .dishRow)
                    }
                    .transition(.opacity)
                case .empty:
                    AteEmptyState(line: "Nothing here\nyet.", art: .rail)
                        .browseFillsPage()
                case .failed(let message):
                    AteEmptyState(line: message, art: .torn, pill: (title: "Try again", action: retry))
                        .browseFillsPage()
                case .ready:
                    rows
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.phase)
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.snug)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ateGround()
        .ateInlineTitle(store.tag.label, subtitle: tag.city.map { AteCity.displayName(for: $0) })
        .refreshable { await store.refresh() }
        .task {
            await store.loadIfNeeded()
            guard hasRecordedView == false else { return }
            hasRecordedView = true
            context.services.analytics(DetailEvents.tagDishesViewed(kind: store.tag.kind))
        }
        .accessibilityIdentifier("tag.ranked")
    }

    @ViewBuilder
    private var rows: some View {
        // Letter tiles chosen down the whole list, so no two neighbours match.
        let letters = DishLetter.neighbourly(store.dishes.map { ($0.dishID, $0.name) })
        ForEach(Array(store.dishes.enumerated()), id: \.element.id) { index, dish in
            AteDishRow(
                photo: .dish(letters[index], cover: dish.coverURLString),
                name: dish.name,
                subtitle: dish.restaurantName,
                score: dish.score.map(AteScore.average),
                isFirst: index == 0,
                onOpen: { open(dish) }
            )
            .accessibilityIdentifier("tag.dish")
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

    private func open(_ dish: SimilarDish) {
        DishPreviews.shared.note(DishPreview(similar: dish))
        context.open(.dish(dish.dishID), from: .tag)
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

enum V2TagMetrics {
    static let skeletonRows = 6
}
