import AteKit
import SwiftUI

/// **`You`** — the record, as a statement.
///
/// Who you are, the three totals on receipt paper, the shape of your own scoring, the dishes you
/// gave five to, and the way into this month's statement. Nothing here is an invitation: a journal
/// with nothing in it shows zeros and an empty chart, because zeros *are* the state and a first-run
/// pep talk would be helper copy (design rule 1).
struct YouScreen: View {
    let store: YouStore
    /// A histogram bar, or "Your ratings ›".
    var onRatings: (Double) -> Void = { _ in }
    /// A dish tile.
    var onDish: (UUID) -> Void = { _ in }
    /// The statement row.
    var onStatement: (StatementMonth) -> Void = { _ in }
    /// The gear.
    var onSettings: () -> Void = {}
    /// Fired once per appearance.
    var onViewed: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let summary = store.summary {
                    AteStatsSlip(cells: [
                        (summary.orders.formatted(), "Orders"),
                        (summary.places.formatted(), "Places"),
                        (summary.dishes.formatted(), "Dishes")
                    ])
                }
                ratings
                perfect
                statement
            }
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentTop(YouScreen.contentTop)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .topTrailing) { settings }
        .refreshable { await store.refresh() }
        .task {
            await store.loadIfNeeded()
            onViewed()
        }
    }

    /// `padding:70px 20px 0` — You starts a little lower than the rest, because the 76pt avatar is
    /// the biggest thing at the top of any screen in the app.
    private static let contentTop: CGFloat = 70

    // MARK: - Bands

    /// `top:60px; right:12px` — the way into Settings.
    private var settings: some View {
        AteIconButton(icon: .settings, label: "Settings", size: 22, action: onSettings)
            .padding(.trailing, AteMetrics.regular)
            .ateContentTop()
    }

    @ViewBuilder
    private var header: some View {
        switch store.phase {
        case .loading:
            YouHeaderSkeleton()
        case .unavailable:
            // No session, or the header would not load. The page says who is missing and stops.
            AteEmptyState(title: "Nobody's\nsigned in.")
        case .ready(let summary):
            HStack(spacing: AteMetrics.loose) {
                AteAvatar(
                    userID: summary.userID,
                    handle: summary.username,
                    side: 76,
                    textStyle: .avatarMonogram
                )
                VStack(alignment: .leading, spacing: AteMetrics.tight) {
                    Text(verbatim: "@\(summary.username)")
                        .ateTextLine(.profileTitle)
                    if let city = summary.city, city.isEmpty == false {
                        Text(city)
                            .ateText(.meta)
                            .foregroundStyle(AtePalette.automatic.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "Your ratings ›" and the chart. Absent entirely until something has been scored — an empty
    /// chart under a heading is a heading about nothing.
    @ViewBuilder
    private var ratings: some View {
        if store.histogram.isEmpty == false {
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                Button {
                    guard let score = store.histogram.busiestScore else { return }
                    onRatings(score)
                } label: {
                    HStack(spacing: AteMetrics.snug) {
                        Text("Your ratings").ateText(.control)
                        Spacer(minLength: 0)
                        AteIcon.chevron.view(size: 15)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("you.ratings")
                ScoreHistogramView(histogram: store.histogram, onSelect: onRatings)
            }
        }
    }

    /// "Your 5.0s" — up to four, tilted, because a small static cluster is exactly where the design
    /// allows tilt (rule 6).
    @ViewBuilder
    private var perfect: some View {
        if store.perfect.isEmpty == false {
            VStack(alignment: .leading, spacing: AteMetrics.snug + 2) {
                Text("Your 5.0s").ateText(.control)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(store.perfect.prefix(4).enumerated()), id: \.element.id) { index, dish in
                        Button { onDish(dish.dishID) } label: {
                            VStack(spacing: AteMetrics.snug) {
                                AtePhotoTile(
                                    photo: .dish(dish.dishID, name: dish.dishName, cover: dish.coverURL),
                                    side: YouScreen.tileSide
                                )
                                .rotationEffect(.degrees(YouScreen.tileAngles[index % 4]))
                                Text(dish.dishName)
                                    .ateText(.tileCaption)
                                    .multilineTextAlignment(.center)
                                    // Two lines, as the artboard's longest caption takes. A dish
                                    // name is never truncated in a slip's stack — there it IS the
                                    // item — but here the tile is the item and the name labels it.
                                    .lineLimit(2)
                                    // A single word wider than the 80pt column ("Cheeseburger" is,
                                    // in Bricolage at 12) breaks mid-word rather than wrapping.
                                    // Shrinking it a fraction is the lesser of the two.
                                    .minimumScaleFactor(0.82)
                                    .foregroundStyle(AtePalette.automatic.fg)
                            }
                            .frame(width: YouScreen.tileColumn)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(dish.dishName)
                        if index < min(4, store.perfect.count) - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `width:80px` per column, a 78pt photo in it.
    private static let tileColumn: CGFloat = 80
    private static let tileSide: CGFloat = 78
    /// Fixed per position, never random: the same four dishes look the same every time the tab opens.
    private static let tileAngles: [Double] = [-4, 3, -3, 4]

    /// "September statement ›", ruled above and below. Only where a month exists — a statement is
    /// printed, and a month with nothing in it was never printed (design rule 4).
    @ViewBuilder
    private var statement: some View {
        if let month = store.month {
            Button { onStatement(month) } label: {
                VStack(spacing: 0) {
                    AteHairline()
                    HStack(spacing: AteMetrics.regular) {
                        AteIcon.journal.view(size: 20)
                        Text("\(month.title) statement").ateText(.control)
                        Spacer(minLength: 0)
                        AteIcon.chevron.view(size: 15)
                    }
                    .frame(minHeight: AteMetrics.rowHeight)
                    AteHairline()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("you.statement")
        }
    }
}

/// The header before it has arrived — the shape of a name and the shape of the totals, never a
/// spinner (design: skeletons of the real components).
private struct YouHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: AteMetrics.loose) {
                Circle()
                    .fill(AtePalette.automatic.hairline)
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: AteMetrics.snug) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AtePalette.automatic.hairline)
                        .frame(width: 150, height: 26)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AtePalette.automatic.hairline)
                        .frame(width: 90, height: 13)
                }
            }
            AteStatsSlip(cells: [("—", "Orders"), ("—", "Places"), ("—", "Dishes")])
                .opacity(0.5)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("You") {
    YouScreen(store: YouStore(stats: InMemoryStatsService()))
        .ateGround()
}
#endif
