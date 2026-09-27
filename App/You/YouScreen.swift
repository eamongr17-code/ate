import AteKit
import SwiftUI

/// **`You`** — the record, as a statement.
///
/// Who you are, the three totals on receipt paper, the shape of your own scoring and the dishes you
/// gave five to. The way into the monthly statement is hidden for now (round 4) — the row, the
/// `Recap` page and its route are all kept, behind ``showsStatement``. Nothing here is an invitation: a journal
/// with nothing in it shows zeros and an empty chart, because zeros *are* the state and a first-run
/// pep talk would be helper copy (design rule 1).
struct YouScreen: View {
    let store: YouStore
    /// A histogram bar (the page scrolled to that bar's group), or "Your ratings ›" (its top).
    var onRatings: (Double) -> Void = { _ in }
    /// A dish tile.
    var onDish: (UUID) -> Void = { _ in }
    /// The statement row.
    var onStatement: (StatementMonth) -> Void = { _ in }
    /// The gear.
    var onSettings: () -> Void = {}
    /// Fired once per appearance.
    var onViewed: () -> Void = {}

    /// Round 4: the statement's entry point is off. Flip to bring the row back; nothing else changes.
    static let showsStatement = false

    var body: some View {
        ScrollView {
            // The page fills in once (round 4): the whole layout as still shapes until every band is
            // in, then one fade — never a header with the chart popping in under it.
            Group {
                if store.phase == .loading {
                    YouPageSkeleton()
                        .transition(.opacity)
                } else {
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
                        if Self.showsStatement { statement }
                    }
                    .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: store.phase == .loading)
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentTop(YouScreen.contentTop)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
        .ateTabBarTracking() // the tab bar's shadow and re-expansion, as on every tab
        .task {
            await store.loadIfNeeded()
            onViewed()
        }
    }

    /// The header is a 56pt row, so the page starts where `Feed` and `Search` start theirs (62) —
    /// Eamon's resized header (2026-09-26), replacing `You.dc.html`'s 76pt avatar at 70.
    private static let contentTop: CGFloat = 62
    static let avatar: CGFloat = 56
    /// "Your ratings ›" is one line of `.control` (15 × 1.2 = 18); a finger gets 44.
    private static let ratingsHit = AteHitOutset(height: 18)

    // MARK: - Bands

    @ViewBuilder
    private var header: some View {
        switch store.phase {
        case .loading:
            YouHeaderSkeleton()
        case .unavailable:
            // No session, or the header would not load. The page says who is missing and stops.
            AteEmptyState(title: "Nobody's\nsigned in.")
        case .ready(let summary):
            header(summary)
        }
    }

    /// **The header** — approved by Eamon 2026-09-26 over `You.dc.html`'s (avatar and handle too
    /// big, the gear too close, long handles unhandled): a 56pt avatar, the handle at 26 on ONE line
    /// that truncates at its tail, and the gear in the same row with a fixed gap between it and the
    /// handle — so a long handle ends in an ellipsis instead of running under the gear.
    private func header(_ summary: ProfileSummary) -> some View {
        HStack(spacing: AteMetrics.regular) {
            AteAvatar(
                userID: summary.userID,
                handle: summary.username,
                side: YouScreen.avatar,
                textStyle: .avatarMonogramCompact
            )
            VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                Text(verbatim: "@\(summary.username)")
                    .ateText(.youHandleCompact)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let city = summary.city, city.isEmpty == false {
                    Text(city)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            AteIconButton(icon: .settings, label: "Settings", size: 22, action: onSettings)
                .ateCornerGlass() // the chrome's glass, like every top-corner button (round 5)
                .padding(.leading, AteMetrics.tight)
                // The glyph sits on the gutter, like every other trailing mark; the hit area
                // hangs past it.
                .padding(.trailing, -(AteMetrics.hit - 22) / 2)
        }
    }

    /// "Your ratings ›" and the chart. Absent entirely until something has been scored — an empty
    /// chart under a heading is a heading about nothing.
    @ViewBuilder
    private var ratings: some View {
        if store.histogram.isEmpty == false {
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                Button {
                    // The whole page, from its top: every group, the highest first.
                    guard let score = store.histogram.highestScore else { return }
                    onRatings(score)
                } label: {
                    HStack(spacing: AteMetrics.snug) {
                        Text("Your ratings").ateText(.control)
                        Spacer(minLength: 0)
                        AteIcon.chevron.view(size: 15)
                    }
                    .ateHitArea(Self.ratingsHit)
                }
                .buttonStyle(.plain)
                .ateHitFootprint(Self.ratingsHit)
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
                                // Two lines, as the artboard's longest caption takes. A single
                                // word wider than the 80pt column ("Cheeseburger" at the larger
                                // text sizes) is set down until it fits rather than broken
                                // mid-word (``WordFittingLabel``).
                                AteExactText(
                                    text: dish.dishName,
                                    style: .tileCaption,
                                    alignment: .center,
                                    colour: AtePalette.automatic.fg,
                                    lineLimit: 2
                                )
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

/// **The whole page before it has arrived** — header, totals, the chart and the tiles, as the still
/// shapes they are waiting for (round 4: staged loading; no shimmer, no breathing).
private struct YouPageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            YouHeaderSkeleton()
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AtePalette.automatic.hairline)
                    .frame(width: 104, height: 18)
                ScoreHistogramSkeleton()
            }
            VStack(alignment: .leading, spacing: AteMetrics.snug + 2) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AtePalette.automatic.hairline)
                    .frame(width: 84, height: 18)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: 78), style: .continuous)
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 78, height: 78)
                            .frame(width: 80)
                        if index < 3 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The header before it has arrived — the shape of a name and the shape of the totals, never a
/// spinner (design: skeletons of the real components).
private struct YouHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: AteMetrics.regular) {
                Circle()
                    .fill(AtePalette.automatic.hairline)
                    .frame(width: YouScreen.avatar, height: YouScreen.avatar)
                VStack(alignment: .leading, spacing: AteMetrics.snug) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AtePalette.automatic.hairline)
                        .frame(width: 150, height: 22)
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
