import AteKit
import SwiftUI

/// The two shelves: your slips under their months, and the dishes you kept under their places —
/// every slip, divider, place and dish one row of the page's own lazy stack (a lazy stack nested in
/// another page's content is the shape that once locked the Feed's main thread).
extension JournalRoot {

    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                segment
                    .id(Self.top)
                switch shelf {
                case .journal: journalRows
                case .saved: savedRows
                }
            }
            .scrollTargetLayout()
            // The slips fill in over their skeletons in one fade.
            .ateAnimation(AteMotion.fillIn, value: journal.phase)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
        .ateRootCollapse($isCollapsed)
        .refreshable { await refresh() }
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: JournalShelfMetrics.visibleShare) { visible in
            noteTopMonth(visible)
        }
        // Fingers together on the list zoom out to its month.
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            guard shelf == .journal, zoom == .list, let next = zoom.pinched(value.magnification) else { return }
            step(to: next, via: .pinch)
        })
    }

    /// Journal | Saved, at the head of the list.
    var segment: some View {
        Picker("Shelf", selection: $shelf) {
            Text("Journal").tag(Shelf.journal)
            Text("Saved").tag(Shelf.saved)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.vertical, AteMetrics.tight)
        .accessibilityIdentifier("journal.shelf")
    }

    // MARK: - Empty

    /// A state with nothing under it: the one empty anatomy, centred in the page under the segment.
    func emptyBand(_ state: AteEmptyState) -> some View {
        state.containerRelativeFrame(.vertical) { length, _ in
            max(length - JournalShelfMetrics.segmentBand, JournalShelfMetrics.emptyMinimum)
        }
    }

    // MARK: - The Journal

    @ViewBuilder
    private var journalRows: some View {
        switch journal.phase {
        case .loading:
            ForEach(0..<JournalShelfMetrics.skeletons, id: \.self) { _ in
                AteSkeleton(kind: .entrySlip)
                    .ateCardWidth()
                    .padding(.top, AteMetrics.slipGap)
            }
            .transition(.opacity)
        case .empty:
            if journal.query.hasFilters {
                // Clear is everything: the order, the range, the city, the months.
                emptyBand(AteEmptyState(line: "Nothing\nlike that.", pill: ("Clear", { apply(BrowseFilters()) })))
            } else {
                emptyBand(AteEmptyState(
                    line: "Nothing\non the tab.",
                    pill: ("Write your first", { compose(ComposerPresentation(origin: .journalEmpty)) })
                ))
            }
        case .signedOut:
            emptyBand(AteEmptyState(line: "Nobody's\nsigned in."))
        case .failed:
            emptyBand(AteEmptyState(line: "Couldn't\nreach Ate.", pill: ("Try again", { retryJournal() })))
        case .ready:
            slips
        }
    }

    private func retryJournal() {
        Task { await journal.refresh() }
    }

    /// The slips, each `slipGap` under the row before it, and over the first slip of each month its
    /// name, scrolling with the list. The gap is **its own row**, not padding on the slip: the inline
    /// title asks which slips are on screen, and a slip's row has to be exactly the slip for that.
    @ViewBuilder
    private var slips: some View {
        let dividers = JournalMonthDividers.dividers(for: journal.entries, sort: journal.query.sort)
        let first = journal.entries.first?.id
        ForEach(journal.entries) { entry in
            if let month = dividers[entry.id] {
                monthDivider(month)
                    .accessibilityIdentifier("journal.month.\(month.year)-\(month.month)")
                    .padding(.top, entry.id == first ? 0 : AteMetrics.slipGap)
                    .id(Self.dividerID(entry.id))
            }
            if entry.id != first || dividers[entry.id] == nil {
                Color.clear
                    .frame(height: AteMetrics.slipGap)
                    .accessibilityHidden(true)
                    .id(Self.gapID(entry.id))
            }
            AteEntrySlip(
                slip: EntrySlipPresentation.journal(entry),
                surface: .journal,
                onOpen: { router.open(.entry(EntryRoute(entry)), from: .journal) },
                onPlace: { router.open(.place($0), from: .journal) },
                onDish: { router.open(.dish($0.dishID), from: .journal) }
            )
            .task { await journal.loadMoreIfNeeded(after: entry) }
            // Its own task, so the row scrolling away cancels the prefetch with it.
            .task { await AtePrefetch.photos(after: entry, in: journal.entries) }
            .ateCardWidth()
            .id(entry.id)
        }
        if let message = journal.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.section)
                .ateCardWidth()
        }
    }

    static func dividerID(_ entry: UUID) -> String { "\(entry.uuidString).month" }
    static func gapID(_ entry: UUID) -> String { "\(entry.uuidString).gap" }

    /// A month's name over its first slip: its count from `journal_days`, and with a filter on, how
    /// many of them the filter keeps.
    private func monthDivider(_ month: AteMonth) -> some View {
        let days = journal.calendarDays
        let query = journal.query
        return AteMonthDivider(
            title: month.name(),
            year: String(month.year),
            count: JournalMonthDividers.count(
                total: days.total(of: month),
                filtered: days.filteredCount(of: month, query: query),
                isFiltered: query.hasFilters
            )
        )
        .task(id: "\(month.year)-\(month.month)-\(query.hashValue)-\(days.revision)") {
            await days.loadYear(month.year)
            if query.hasFilters { await days.loadFilteredCount(month, query: query) }
        }
    }

    private func noteTopMonth(_ visible: [UUID]) {
        guard let top = journal.entries.first(where: { visible.contains($0.id) }) else { return }
        let month = AteMonth.containing(top.createdAt)
        if month != topMonth { topMonth = month }
    }

    // MARK: - Saved

    @ViewBuilder
    private var savedRows: some View {
        switch saved.phase {
        case .loading:
            ForEach(0..<JournalShelfMetrics.skeletonRows, id: \.self) { _ in
                AteSkeleton(kind: .dishRow)
                    .padding(.horizontal, AteMetrics.gutter)
            }
            .padding(.top, AteMetrics.regular)
        case .empty where saved.filter.isEmpty == false:
            // Saved's Clear keeps the Journal's order: Saved has none of its own.
            emptyBand(AteEmptyState(line: "Nothing\nlike that.", pill: ("Clear", { clearSaved() })))
        case .empty:
            emptyBand(AteEmptyState(line: "Nothing saved\nyet."))
        case .signedOut:
            emptyBand(AteEmptyState(line: "Nobody's\nsigned in."))
        case .failed:
            emptyBand(AteEmptyState(line: "Couldn't\nreach Ate.", pill: ("Try again", { retrySaved() })))
        case .ready:
            savedGroups
        }
    }

    private func clearSaved() {
        apply(BrowseFilters(sort: filters.sort))
    }

    private func retrySaved() {
        Task { await saved.refresh() }
    }

    /// Each place a head, its dishes under it. The letter tiles are chosen for the shelf as it reads,
    /// top to bottom, so no two dishes one above the other share an accent.
    @ViewBuilder
    private var savedGroups: some View {
        let shelfDishes = saved.groups.flatMap(\.dishes)
        let letters = Dictionary(
            zip(shelfDishes.map(\.id), DishLetter.neighbourly(shelfDishes.map { ($0.dishID, $0.dishName) })),
            uniquingKeysWith: { first, _ in first }
        )
        ForEach(saved.groups) { group in
            placeHead(group)
                .padding(.horizontal, AteMetrics.gutter)
            ForEach(group.dishes) { dish in
                AteDishRow(
                    photo: .dish(letters[dish.id] ?? DishLetter(dishID: dish.dishID, name: dish.dishName),
                                 cover: dish.dishCoverURL),
                    name: dish.dishName,
                    subtitle: dish.sourceUsername.map { "from @\($0)" },
                    score: dish.dishScore.map { .average($0) },
                    isFirst: dish.id == group.dishes.first?.id,
                    isSaved: true,
                    onSave: { Task { await app.saves.unsaveFromShelf(dish) } },
                    onOpen: { router.open(.dish(dish.dishID), from: .saved) }
                )
                .padding(.horizontal, AteMetrics.gutter)
                .task { await saved.loadMoreIfNeeded(after: dish) }
                .accessibilityIdentifier("saved.dish")
            }
        }
    }

    /// The place, its city, and the chevron onward to its page.
    private func placeHead(_ group: SavedDishGroup) -> some View {
        Button {
            router.open(.place(group.restaurantID), from: .saved)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(group.restaurantName)
                    .ateText(.slipPlace)
                    .foregroundStyle(AtePalette.automatic.fg)
                if let city = group.city {
                    Text(city)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.automatic.muted)
                }
                Spacer(minLength: 0)
                AteIcon.chevron.view(size: JournalShelfMetrics.chevron)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
            .padding(.top, JournalShelfMetrics.placeTop)
            .padding(.bottom, JournalShelfMetrics.placeBottom)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("saved.place")
    }
}

enum JournalShelfMetrics {
    /// How much of a slip must be on screen to count as the one you are reading.
    static let visibleShare = 0.2
    /// The segment's row: its 36 and the 4 above and below.
    static let segmentBand: CGFloat = AteMetrics.segmentHeight + 2 * AteMetrics.tight
    /// An empty state never squeezes below this, however small the screen.
    static let emptyMinimum: CGFloat = 320
    static let skeletons = 3
    static let skeletonRows = 6
    /// A place head: `padding:18px 0 10px`, its chevron 15.
    static let placeTop: CGFloat = 18
    static let placeBottom: CGFloat = 10
    static let chevron: CGFloat = 15
}
