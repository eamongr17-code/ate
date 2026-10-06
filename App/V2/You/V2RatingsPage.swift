import AteKit
import SwiftUI

/// **Your ratings** — every dish you have scored, on one page: the chart, and under it the dishes
/// grouped by score from the highest down, each group opened by its score line.
///
/// A bar is a way down the page, not a filter (Eamon, 26 Sep): tapping one lights it and scrolls to
/// its group. The store reads the groups strictly in order, so everything above the group a tap lands
/// on is already complete and cannot push it down the screen after the scroll.
struct V2RatingsPage: View {
    let score: Double
    let context: V2PageContext

    /// Owned, not handed in: a destination's body is re-evaluated whenever the shell redraws, and a
    /// store built there would reset the page — groups, scroll and all.
    @State private var store: RatingsStore
    /// The score the page was opened on. Scrolled to once, when its group first arrives.
    private let opening: Double
    @State private var hasScrolledToOpening = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(score: Double, context: V2PageContext) {
        self.score = score
        self.context = context
        self.opening = ScoreHistogram.snapped(score)
        _store = State(initialValue: RatingsStore(score: score, stats: context.services.stats))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if store.isSettled {
                        settled(proxy)
                            .transition(.opacity)
                    } else if store.didFail {
                        AteEmptyState(line: "Couldn't\nreach Ate.", art: .torn, pill: (title: "Try again", action: {
                            Task { await store.refresh() }
                        }))
                        .containerRelativeFrame(.vertical)
                    } else {
                        skeleton
                            .transition(.opacity)
                    }
                }
                .ateAnimation(AteMotion.fillIn, value: store.isSettled)
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.top, AteMetrics.regular)
                .padding(.bottom, AteMetrics.section)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .refreshable { await store.refresh() }
            .task {
                await store.loadIfNeeded()
                context.services.analytics(YouEvents.ratingsViewed(score: store.score))
                // Opened from a bar: land on its group. From "Your ratings ›" the opening score is
                // the top group, which is already where the page starts.
                guard hasScrolledToOpening == false else { return }
                hasScrolledToOpening = true
                if store.groups.first?.score != opening {
                    await Task.yield()
                    scroll(to: opening, with: proxy, animated: false)
                }
            }
        }
        .accessibilityIdentifier("v2.ratings")
        .ateGround()
        .ateInlineTitle("Your ratings")
    }

    /// The chart and every group read so far.
    private func settled(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            AteScoreHistogram(histogram: store.histogram, selected: store.score) { score in
                Task {
                    // Latest tap wins: one overtaken by a newer tap neither scrolls nor counts, so
                    // the page always ends on the bar that is lit.
                    guard await store.select(score) else { return }
                    context.services.analytics(YouEvents.ratingsViewed(score: score))
                    scroll(to: score, with: proxy)
                }
            }
            groups
        }
    }

    private func scroll(to score: Double, with proxy: ScrollViewProxy, animated: Bool = true) {
        guard store.group(at: score) != nil else { return }
        let id = Self.groupID(score)
        if animated, reduceMotion == false {
            withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .top) }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    static func groupID(_ score: Double) -> String { "ratings.group.\(ScoreHistogram.halfSteps(score))" }

    /// Every group read so far, highest first. Nothing scored draws nothing under the chart.
    private var groups: some View {
        // Letter tiles chosen down the whole page, so no two neighbours match.
        let all = store.groups.flatMap(\.dishes)
        let letters = Dictionary(
            zip(all.map(\.id), DishLetter.neighbourly(all.map { ($0.dishID, $0.dishName) })),
            uniquingKeysWith: { first, _ in first }
        )
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(store.groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    AteScoreGroupHeader(score: group.score, dishCount: group.dishCount)
                    ForEach(Array(group.dishes.enumerated()), id: \.element.id) { index, dish in
                        row(dish, letter: letters[dish.id], isFirst: index == 0)
                            .task { await store.loadMoreIfNeeded(after: dish) }
                    }
                }
                .padding(.bottom, group.id == store.groups.last?.id ? 0 : AteScoreGroupHeaderMetrics.groupGap)
                .id(Self.groupID(group.score))
            }
        }
    }

    private func row(_ dish: ScoredDish, letter: DishLetter?, isFirst: Bool) -> some View {
        AteDishRow(
            photo: .dish(letter ?? DishLetter(dishID: dish.dishID, name: dish.dishName), cover: dish.coverURL),
            name: dish.dishName,
            subtitle: dish.restaurantName.flatMap { $0.isEmpty ? nil : $0 },
            score: Rating(exactly: dish.score).map(AteScore.personal),
            isFirst: isFirst,
            onOpen: { context.open(.dish(dish.dishID), from: .unknown) }
        )
        .accessibilityIdentifier("ratings.dish")
    }

    /// The page before it has arrived: the chart, a score line and a screenful of rows.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            AteScoreHistogramSkeleton()
            VStack(alignment: .leading, spacing: 0) {
                AteScoreGroupHeaderSkeleton()
                ForEach(0..<V2RatingsPageMetrics.skeletonRows, id: \.self) { _ in
                    AteSkeleton(kind: .dishRow)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private enum V2RatingsPageMetrics {
    static let skeletonRows = 5
}
