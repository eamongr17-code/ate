import AteKit
import SwiftUI

/// **`Ratings`** — every dish you have scored, on one page.
///
/// The title at 38 (`Ratings.dc.html`), the chart, and under it the dishes grouped by score from
/// the highest down. Each group opens on the artboard's own score line — the score, its stars, and
/// how many dishes sit there — and then the artboard's rows: thumbnail, dish, place, date.
///
/// A bar is a way down the page, not a filter (Eamon, 2026-09-26): tapping one lights it and
/// scrolls to its group. The store reads the groups strictly in order, so everything above the
/// group a tap lands on is already complete and cannot push it down the screen after the scroll.
struct RatingsScreen: View {
    var onDish: (UUID) -> Void = { _ in }
    /// Fired for the score the page lands on, and again for every bar tapped on it.
    var onViewed: (Double) -> Void = { _ in }

    /// Owned, not handed in: a navigation destination's body is re-evaluated whenever anything in
    /// the shell around it changes, and a store built in that expression would reset the page —
    /// groups, scroll and all — every time.
    @State private var store: RatingsStore
    /// The score the page was opened on. Scrolled to once, when its group first arrives.
    private let opening: Double
    @State private var hasScrolledToOpening = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        score: Double,
        stats: any StatsReading,
        onDish: @escaping (UUID) -> Void = { _ in },
        onViewed: @escaping (Double) -> Void = { _ in }
    ) {
        self.onDish = onDish
        self.onViewed = onViewed
        self.opening = ScoreHistogram.snapped(score)
        _store = State(initialValue: RatingsStore(score: score, stats: stats))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // `padding:2px 20px 0; gap:16px`.
                VStack(alignment: .leading, spacing: AteMetrics.loose) {
                    AteExactText(text: "Your ratings", style: .ratingsTitle, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    ScoreHistogramView(
                        histogram: store.histogram,
                        selected: store.score,
                        onSelect: { score in
                            Task {
                                // Latest tap wins: one overtaken by a newer tap neither scrolls nor
                                // counts, so the page always ends on the bar that is lit.
                                guard await store.select(score) else { return }
                                onViewed(score)
                                scroll(to: score, with: proxy)
                            }
                        }
                    )
                    groups
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
                // Opened from a bar on You: land on its group. Opened from "Your ratings ›" the
                // opening score is the top group, which is already where the page starts.
                guard hasScrolledToOpening == false else { return }
                hasScrolledToOpening = true
                if store.groups.first?.score != opening {
                    scroll(to: opening, with: proxy, animated: false)
                }
            }
        }
    }

    private func scroll(to score: Double, with proxy: ScrollViewProxy, animated: Bool = true) {
        guard store.group(at: score) != nil else { return }
        let id = RatingsScreen.groupID(score)
        if animated, reduceMotion == false {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    static func groupID(_ score: Double) -> String { "ratings.group.\(ScoreHistogram.halfSteps(score))" }

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

    /// Every group read so far, highest first. Nothing scored draws nothing under the chart: the
    /// empty chart has already said so, and a sentence explaining an empty list is exactly the
    /// helper copy design rule 1 forbids.
    private var groups: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(store.groups) { group in
                VStack(alignment: .leading, spacing: AteMetrics.loose) {
                    scoreLine(group)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.dishes) { dish in
                            row(dish)
                                .task { await store.loadMoreIfNeeded(after: dish) }
                        }
                    }
                }
                // Groups are parted by the page's section gap — the artboard draws one group, so
                // the space between two is the closest thing it has: `24`, the app's section rhythm.
                .padding(.bottom, group.id == store.groups.last?.id ? 0 : AteMetrics.section)
                .id(RatingsScreen.groupID(group.score))
            }
        }
    }

    /// The artboard's score line — the score at 30, its stars, and the count at the other end of
    /// the row, never parted by a dot (design rule 2). `padding-top:4px`.
    private func scoreLine(_ group: RatingsStore.Group) -> some View {
        HStack(spacing: AteMetrics.snug + 2) {
            Text(ScoreFormat.halfStep(group.score))
                .ateText(.ratingsScore)
                .monospacedDigit()
            HStack(spacing: AteMetrics.hairspace) {
                let stars = ScoreFormat.stars(for: group.score)
                ForEach(0..<5, id: \.self) { index in
                    AteStar(fill: fill(index, full: stars.full, half: stars.half), side: 20, lineWidth: 1.5)
                }
            }
            Spacer(minLength: AteMetrics.snug)
            Text(ScoreFormat.dishCount(group.dishCount))
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
        }
        .padding(.top, AteMetrics.tight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func fill(_ index: Int, full: Int, half: Bool) -> Double {
        if index < full { return 1 }
        if index == full, half { return 0.5 }
        return 0
    }

    /// The artboard's row, unchanged: ruled at the top, so the first row is parted from the score
    /// line and the last ends on the ground rather than on a line.
    private func row(_ dish: ScoredDish) -> some View {
        Button { onDish(dish.dishID) } label: {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteThumbnail(
                        photo: .dish(dish.dishID, name: dish.dishName, cover: dish.coverURL),
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
                    // "19 Sep" this year, "19 Sep 2025" in any other.
                    Text(dish.dateLabel())
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .fixedSize()
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
}

#if DEBUG
#Preview("Ratings") {
    RatingsScreen(score: 4.5, stats: InMemoryStatsService())
}
#endif
