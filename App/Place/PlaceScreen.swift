import AteKit
import SwiftUI

/// **`Restaurant`** — the place, and the one question it answers: what should I order here?
///
/// Four bands, in the order `Restaurant.dc.html` sets them down: the name at 44, a row of chips
/// carrying only the facts we actually hold, the ranked menu on receipt paper, and the entries
/// written here — yours under "Your N visits", everyone else's under them.
///
/// The average in the header is **read**, never computed: it is the mean of per-dish averages
/// (data-model §1.2), so averaging the menu below it would print a different, wrong number.
struct PlaceScreen: View {
    let store: PlacePageStore
    var onDish: (UUID) -> Void = { _ in }
    var onOpen: (EntryCard) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }
    var onSave: (EntryCard, AteSlip.Dish) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                header
                menu
                visits
                entries
            }
            .padding(.top, AteMetrics.hairspace)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .refreshable { await store.refresh() }
        .task { await store.load() }
    }

    // MARK: - Bands

    /// `padding:60px 12px 0` — back, and nothing else. There is nothing to do *to* a place.
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    @ViewBuilder
    private var header: some View {
        switch store.header {
        case .loading:
            PlaceHeaderSkeleton()
                .padding(.horizontal, AteMetrics.gutter)
        case .unavailable:
            // Deleted, or behind a block. Say that, and nothing else (design rule 1).
            AteEmptyState(title: "This place\nisn't here.")
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 10) {
                AteExactText(text: summary.name, style: .placeTitle, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                facts
            }
            .padding(.horizontal, AteMetrics.gutter)
        }
    }

    /// `gap:6px` — the average, how many people, the cuisine, the suburb. Each one is drawn only
    /// when we hold it: a place with no cuisine on file shows three chips, never a placeholder
    /// (design rule 8).
    private var facts: some View {
        HStack(spacing: 6) {
            ForEach(store.facts) { fact in
                switch fact {
                case .rating(let value):
                    AteChip(icon: .starFilled, title: value, iconSize: 14)
                        .accessibilityLabel("Rated \(value) out of 5")
                case .people(let value):
                    AteChip(icon: .feed, title: value, iconSize: 15)
                        .accessibilityLabel("\(value) people")
                case .word(let value):
                    AteChip(title: value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **What to order** — the ranked menu, on the one piece of receipt paper this page carries.
    @ViewBuilder
    private var menu: some View {
        switch store.menu {
        case .loading:
            MenuSkeleton()
                .padding(.horizontal, AteMetrics.gutter)
        case .failed:
            EmptyView()
        case .ready where store.dishes.isEmpty:
            // Nobody has written up a dish here yet. Not an error, and not an instruction.
            AteEmptyState(title: "Nothing\nordered yet.")
        case .ready:
            VStack(alignment: .leading, spacing: 0) {
                Text("What to order")
                    .ateText(.receiptLabel)
                    .foregroundStyle(AtePalette.paper.fg)
                    .padding(.bottom, AteMetrics.regular)
                ForEach(Array(store.dishes.enumerated()), id: \.element.id) { index, dish in
                    MenuDishRow(dish: dish, rank: index + 1) { onDish(dish.dishID) }
                        .task { await store.loadMoreDishesIfNeeded(after: dish) }
                }
            }
            .padding(.top, AteMetrics.loose)
            .padding(.horizontal, AteMetrics.loose)
            // `padding:16px 16px 6px`, plus the paper's own torn edge under it.
            .padding(.bottom, 6 + AteMetrics.tornEdgeHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atePaper()
            .background(AteColor.paper, in: ReceiptPaper())
            .padding(.horizontal, AteMetrics.gutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("place.menu")
        }
    }

    /// **Your N visits** — the viewer's own entries here, on the same dish-first slip the feed
    /// uses. Absent at zero: a place you have never been to does not say so.
    @ViewBuilder
    private var visits: some View {
        if store.hasVisits {
            VStack(alignment: .leading, spacing: AteMetrics.slipGap) {
                band(icon: .journal, title: store.myVisits == 1 ? "Your 1 visit" : "Your \(store.myVisits) visits")
                    .accessibilityIdentifier("place.visits")
                slips(store.visits, identifier: "place.visit") { EntrySlipPresentation.profile($0) }
            }
        }
    }

    /// Everybody else's visits here, newest first.
    @ViewBuilder
    private var entries: some View {
        switch store.entries.phase {
        case .loading:
            SlipSkeleton(count: 1, hasByline: true)
                .padding(.horizontal, AteMetrics.gutter)
        case .empty, .signedOut:
            EmptyView()
        case .failed(let message):
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
        case .ready:
            slips(store.entries, identifier: "place.slip") { EntrySlipPresentation.feed($0) }
        }
    }

    // MARK: - Pieces

    /// The ruled band that names a section: an icon, a title, and rules above and below it — the
    /// artboard's `border-top` + `border-bottom` row. No chevron: the list is directly underneath,
    /// and an arrow pointing at something already on screen is a lie.
    private func band(icon: AteIcon, title: String) -> some View {
        VStack(spacing: 0) {
            AteHairline()
            HStack(spacing: AteMetrics.regular) {
                icon.view(size: 20)
                Text(title).ateText(.rowTitle)
                Spacer(minLength: 0)
            }
            .frame(minHeight: AteMetrics.rowHeight)
            AteHairline()
        }
        .padding(.horizontal, AteMetrics.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func slips(
        _ list: EntryListStore,
        identifier: String,
        presentation: @escaping (EntryCard) -> AteSlip
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            ForEach(list.entries) { entry in
                EntrySlip(
                    slip: presentation(entry),
                    onOpen: { onOpen(entry) },
                    onProfile: entry.isMine ? nil : { onProfile(entry.authorID) },
                    onSave: entry.isMine ? nil : { onSave(entry, $0) },
                    // No `onPlace`: every slip here is at *this* place, so its pin would be a door
                    // back into the room it is already in. It stays printed, and stays inert.
                    onDish: { onDish($0.dishID) },
                    identifier: identifier
                )
                .task { await list.loadMoreIfNeeded(after: entry) }
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
    }
}

/// One line of **what to order**: the rank, a straight 48pt thumbnail (design rule 6 — nothing in a
/// list tilts), the dish, how many people have scored it, and the score printed like a price.
struct MenuDishRow: View {
    let dish: MenuDish
    /// 1-based, and a fact about the *list* rather than about the dish — so it is handed in.
    let rank: Int
    let action: () -> Void

    /// `min-height:66px; gap:12px`, ruled at the top with the receipt's own dashed line.
    private static let height: CGFloat = 66
    private static let thumbnail: CGFloat = 48
    /// `.lab` at `width:18px` — the rank column, so every dish name starts on the same vertical.
    private static let rankWidth: CGFloat = 18

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                AteDashedLine(opacity: 0.25)
                HStack(spacing: AteMetrics.regular) {
                    Text(String(format: "%02d", rank))
                        .ateText(.receiptLabel)
                        .frame(width: Self.rankWidth, alignment: .leading)
                    AtePhotoTile(
                        photo: AtePhoto(url: dish.coverURL),
                        side: Self.thumbnail
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dish.name)
                            .ateText(.menuDish)
                            // The dish IS the item; an elided one is a dish nobody can recognise.
                            .fixedSize(horizontal: false, vertical: true)
                        if dish.peopleCount > 0 {
                            HStack(spacing: AteMetrics.tight) {
                                AteIcon.feed.view(size: 13)
                                Text(dish.peopleCount.formatted()).ateText(.meta)
                            }
                            .foregroundStyle(AtePalette.paper.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    score
                }
                .frame(minHeight: Self.height)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("place.dish")
    }

    /// Design rule 7: an unscored dish gets the empty star at full strength, never a zero and never
    /// a dimmed control.
    @ViewBuilder
    private var score: some View {
        if let value = dish.score {
            Text(ScoreFormat.average(value))
                .ateText(.menuScore)
                .monospacedDigit()
                .accessibilityLabel("Rated \(ScoreFormat.average(value)) out of 5")
        } else {
            UnscoredMark(side: 22)
                .foregroundStyle(AtePalette.paper.muted)
        }
    }
}

/// The header before it has arrived — the shape of a name and its chips, not a spinner.
private struct PlaceHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 220, height: 40)
            HStack(spacing: 6) {
                ForEach([64.0, 58.0, 82.0], id: \.self) { width in
                    Capsule()
                        .fill(AtePalette.automatic.hairline)
                        .frame(width: width, height: AteMetrics.chipHeight)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// …and the menu, drawn as the paper it is waiting for.
private struct MenuSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AtePalette.paper.hairline)
                .frame(width: 96, height: 11)
                .padding(.bottom, AteMetrics.regular)
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: 0) {
                    AteDashedLine(opacity: 0.25)
                    HStack(spacing: AteMetrics.regular) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AtePalette.paper.hairline)
                            .frame(width: 48, height: 48)
                            .padding(.leading, 18 + AteMetrics.regular)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AtePalette.paper.hairline)
                            .frame(width: 150, height: 16)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 66)
                }
            }
        }
        .padding(.top, AteMetrics.loose)
        .padding(.horizontal, AteMetrics.loose)
        .padding(.bottom, 6 + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
        .accessibilityHidden(true)
    }
}
