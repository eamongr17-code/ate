import AteKit
import SwiftUI

/// **`Ratings`** — one bar of your histogram, opened.
///
/// The same chart as `You` with the tapped bar lit coral, the score itself beside its stars, how
/// many dishes sit there, and then the dishes: name, place, date. Tapping another bar moves the
/// whole page rather than pushing a second copy of it — the chart is the navigation.
struct RatingsScreen: View {
    var onDish: (UUID) -> Void = { _ in }
    /// Fired for the score the page lands on, and again for every bar tapped on it.
    var onViewed: (Double) -> Void = { _ in }

    /// Owned, not handed in: a navigation destination's body is re-evaluated whenever anything in
    /// the shell around it changes, and a store built in that expression would reset the page —
    /// bar, list and all — every time.
    @State private var store: RatingsStore
    @Environment(\.dismiss) private var dismiss

    init(
        score: Double,
        stats: any StatsReading,
        onDish: @escaping (UUID) -> Void = { _ in },
        onViewed: @escaping (Double) -> Void = { _ in }
    ) {
        self.onDish = onDish
        self.onViewed = onViewed
        _store = State(initialValue: RatingsStore(score: score, stats: stats))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                Text("Your ratings").ateText(.screenTitle)
                ScoreHistogramView(
                    histogram: store.histogram,
                    selected: store.score,
                    onSelect: { score in
                        Task {
                            await store.select(score)
                            onViewed(score)
                        }
                    }
                )
                summary
                rows
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .refreshable { await store.refresh() }
        .task {
            await store.loadIfNeeded()
            onViewed(store.score)
        }
    }

    /// `padding:60px 12px 0` — back, and nothing else. The page's name is its title.
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    /// The score, its stars, and the count — the two values at opposite ends of the row, never
    /// parted by a dot (design rule 2).
    private var summary: some View {
        HStack(spacing: AteMetrics.snug + 2) {
            Text(ScoreFormat.halfStep(store.score))
                .ateText(.ratingsScore)
                .monospacedDigit()
            HStack(spacing: AteMetrics.hairspace) {
                let stars = ScoreFormat.stars(for: store.score)
                ForEach(0..<5, id: \.self) { index in
                    AteStar(fill: fill(index, full: stars.full, half: stars.half), side: 20, lineWidth: 1.5)
                }
            }
            Spacer(minLength: AteMetrics.snug)
            Text(ScoreFormat.dishCount(store.dishCount))
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
        }
        .padding(.top, AteMetrics.tight)
        .accessibilityElement(children: .combine)
    }

    private func fill(_ index: Int, full: Int, half: Bool) -> Double {
        if index < full { return 1 }
        if index == full, half { return 0.5 }
        return 0
    }

    /// A dish per review, newest first. Ruled at the top, so the first row is parted from the score
    /// line and the last ends on the ground rather than on a line. Nothing at this score draws
    /// nothing: the chart above has already said so, and a sentence under it explaining the empty
    /// list is exactly the helper copy design rule 1 forbids.
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(store.dishes) { dish in
                row(dish)
                    .task { await store.loadMoreIfNeeded(after: dish) }
            }
        }
    }

    private func row(_ dish: ScoredDish) -> some View {
        Button { onDish(dish.dishID) } label: {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteThumbnail(
                        photo: AtePhoto(
                            id: dish.dishID,
                            url: dish.coverURL.flatMap(URL.init(string:))
                        ),
                        side: RatingsScreen.thumbnail
                    )
                    VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                        Text(dish.dishName).ateText(.rowTitle)
                        if let place = dish.restaurantName, place.isEmpty == false {
                            Text(place)
                                .ateText(.meta)
                                .foregroundStyle(AtePalette.automatic.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(dish.createdAt.formatted(RatingsScreen.dateFormat))
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                }
                .frame(minHeight: RatingsScreen.rowHeight)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ratings.dish")
    }

    /// `min-height:76px` and a 56pt square — this list's own row, taller than the app's 58 because
    /// the thumbnail sets it.
    private static let rowHeight: CGFloat = 76
    private static let thumbnail: CGFloat = 56

    /// "19 Sep". The order is the design's; the month's NAME is the reader's locale's.
    static let dateFormat = Date.VerbatimFormatStyle(
        format: "\(day: .defaultDigits) \(month: .abbreviated)",
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent
    )
}

#if DEBUG
#Preview("Ratings") {
    RatingsScreen(score: 4.5, stats: InMemoryStatsService())
}
#endif
