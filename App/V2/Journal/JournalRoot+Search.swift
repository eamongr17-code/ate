import AteKit
import SwiftUI

/// **Searching your own record** (`lists-notifications.html` section 2, option A): the magnifier
/// turns the header row into the search field with its close disc; the switch and the slips step
/// away under it. Before two characters, your recent searches; then your entries whose words, place
/// or dishes match, as the Journal's own slips (`search_my_entries` answers one flat list of entries,
/// not the mockup's Dishes / Places / Entries groups). Close puts back the shelf you were on.
extension JournalRoot {
    /// The magnifier: the store is made on first use and kept, so recents and the last answer survive
    /// a close.
    func openSearch() {
        if search == nil {
            search = JournalSearchStore(
                service: app.services.journalSearch,
                recents: JournalSearchStore.recents(owner: app.services.photoOwner),
                analytics: app.services.analytics
            )
        }
        search?.opened()
        searchText = ""
        search?.cancel()
        withAnimation(reduceMotion ? nil : AteMotion.fillIn) { isSearching = true }
    }

    func closeSearch() {
        search?.cancel()
        searchText = ""
        withAnimation(reduceMotion ? nil : AteMotion.fillIn) { isSearching = false }
    }

    @ViewBuilder
    var searchOverlay: some View {
        if isSearching, let search {
            JournalSearchScreen(
                store: search,
                text: $searchText,
                onOpen: { card in
                    search.opened(card)
                    router.open(.entry(EntryRoute(card)), from: .journal)
                },
                onPlace: { router.open(.place($0), from: .journal) },
                onDish: { router.open(.dish($0.dishID), from: .journal) },
                onClose: closeSearch
            )
            .transition(.opacity)
        }
    }
}

/// The search screen itself: the field across the header row, then recents, results or the one empty
/// line. Thin: every decision is ``JournalSearchStore``'s.
private struct JournalSearchScreen: View {
    let store: JournalSearchStore
    @Binding var text: String
    let onOpen: (EntryCard) -> Void
    let onPlace: (UUID) -> Void
    let onDish: (AteSlip.Dish) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AteGlassSearchField(
                text: $text,
                prompt: JournalSearchCopy.prompt,
                identifier: "journal.search.field",
                onSubmit: { Task { await store.submit() } },
                onClose: onClose
            )
            .padding(.horizontal, JournalSearchMetrics.barInset)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.bottom, AteMetrics.section)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
        .ateGround()
        .onChange(of: text) { _, now in store.setQuery(now) }
        .accessibilityIdentifier("journal.search")
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            recents
        case .searching:
            ForEach(0..<JournalShelfMetrics.skeletons, id: \.self) { _ in
                AteSkeleton(kind: .entrySlip)
                    .ateCardWidth()
                    .padding(.top, AteMetrics.slipGap)
            }
        case .ready:
            results
        case .empty:
            AteEmptyState(line: JournalSearchCopy.empty)
                .containerRelativeFrame(.vertical) { height, _ in height * JournalSearchMetrics.emptyShare }
                .accessibilityIdentifier("journal.search.empty")
        case .failed:
            AteEmptyState(line: JournalSearchCopy.unreachable, pill: (JournalSearchCopy.retry, {
                Task { await store.submit() }
            }))
            .containerRelativeFrame(.vertical) { height, _ in height * JournalSearchMetrics.emptyShare }
        }
    }

    /// Your recent searches, the kit's recent row; nothing at all when there are none.
    private var recents: some View {
        ForEach(Array(store.recents.items.enumerated()), id: \.element.id) { index, recent in
            AteRecentSearchRow(text: recent.text, isFirst: index == 0) {
                text = recent.text
                Task { await store.select(recent) }
            }
            .padding(.horizontal, AteMetrics.gutter)
        }
        .padding(.top, JournalSearchMetrics.recentsTop)
    }

    private var results: some View {
        ForEach(store.results) { card in
            Color.clear
                .frame(height: AteMetrics.slipGap)
                .accessibilityHidden(true)
            AteEntrySlip(
                slip: EntrySlipPresentation.journal(card),
                surface: .journal,
                onOpen: { onOpen(card) },
                onPlace: onPlace,
                onDish: onDish
            )
            .task { await store.loadMoreIfNeeded(after: card) }
            .ateCardWidth()
        }
    }
}

enum JournalSearchCopy {
    static let prompt = "Search your journal"
    static let empty = "Not in\nyour record."
    static let unreachable = "Couldn't\nreach Ate."
    static let retry = "Try again"
}

enum JournalSearchMetrics {
    /// `.nav{left:16px; right:16px}`.
    static let barInset: CGFloat = 16
    /// The recents start 16 under the field (`top:116px` against the row's 100).
    static let recentsTop: CGFloat = 16
    static let emptyShare: CGFloat = 0.7
}
