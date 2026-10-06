import AteKit
import SwiftUI

/// The list: your slips under their months — every slip and divider one row of the page's own lazy
/// stack (a lazy stack nested in another page's content is the shape that once locked the Feed's
/// main thread).
extension JournalRoot {

    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.top)
                journalRows
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
    }

    // MARK: - Empty

    /// A state with nothing under it: the one empty anatomy, centred in the page.
    func emptyBand(_ state: AteEmptyState) -> some View {
        state.containerRelativeFrame(.vertical) { length, _ in
            max(length, JournalShelfMetrics.emptyMinimum)
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
                emptyBand(AteEmptyState(line: "Nothing\nlike that.", art: .search,
                    pill: ("Clear", { apply(BrowseFilters()) })))
            } else {
                emptyBand(AteEmptyState(
                    line: "Nothing\non the tab.", art: .journal,
                    pill: ("Write your first", { compose(ComposerPresentation(origin: .journalEmpty)) })
                ))
            }
        case .signedOut:
            emptyBand(AteEmptyState(line: "Nobody's\nsigned in.", art: .printer))
        case .failed:
            emptyBand(AteEmptyState(line: "Couldn't\nreach Ate.", art: .torn, pill: ("Try again", { retryJournal() })))
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
        ForEach(journal.entries) { entry in
            if let month = dividers[entry.id] {
                monthDivider(month)
                    .accessibilityIdentifier("journal.month.\(month.year)-\(month.month)")
                    .id(Self.dividerID(entry.id))
            }
            Color.clear
                .frame(height: AteMetrics.slipGap)
                .accessibilityHidden(true)
                .id(Self.gapID(entry.id))
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

    /// A month's name over its first slip — the year beside it only when it is not this one.
    private func monthDivider(_ month: AteMonth) -> some View {
        let isThisYear = month.year == AteMonth.containing(Date()).year
        return AteMonthHeading(month: month.name(), year: isThisYear ? nil : String(month.year))
    }

    private func noteTopMonth(_ visible: [UUID]) {
        guard let top = journal.entries.first(where: { visible.contains($0.id) }) else { return }
        let month = AteMonth.containing(top.createdAt)
        if month != topMonth { topMonth = month }
    }
}

enum JournalShelfMetrics {
    /// How much of a slip must be on screen to count as the one you are reading.
    static let visibleShare = 0.2
    /// An empty state never squeezes below this, however small the screen.
    static let emptyMinimum: CGFloat = 320
    static let skeletons = 3
}
