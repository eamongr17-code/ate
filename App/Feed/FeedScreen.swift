import AteKit
import SwiftUI

/// **`Feed`** — everyone else's visits, newest first. The one place you go to decide where to eat
/// next, which is why its only action is Save (PRODUCT.md decision 7): no likes, no comments, no
/// follows.
///
/// Your own entries are not here. They are the journal, and a feed that shows them back to you is
/// the journal with a byline on it (`get_entry_feed` excludes them server-side).
struct FeedScreen: View {
    let store: EntryListStore
    /// Which area the feed is about — the location pill, and what it reloads.
    var area: FeedAreaModel?
    /// Bumped when the Feed tab is tapped while already current.
    var scrollToTopSignal = 0
    var onOpen: (EntryCard) -> Void = { _ in }
    var onProfile: (UUID) -> Void = { _ in }
    /// A slip's pin line and its dish rows — the same doors they are in the journal and on a
    /// profile (AGENTS.md rule 2).
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    var onSave: (EntryCard, AteSlip.Dish) -> Void = { _, _ in }
    var onViewed: () -> Void = {}

    @State private var isChoosingArea = false
    @State private var scrollToTopAfterArea = 0

    var body: some View {
        ScrollView {
            // The scroll view's content IS the lazy stack, and every slip is one of its own rows —
            // never a `LazyVStack` inside a `VStack` under the header. Nested like that, the scroll
            // view re-sizes all of its content on each pass, which re-places the lazy stack, which
            // flips a slip it is prefetching below the fold between two states, and the flip dirties
            // the content size again: coming back to a Feed scrolled to mid-list locked the main
            // thread for minutes. As the stack's own rows, it settles.
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            // Loading is the column of skeleton slips, still; the feed replaces it in one fade. On
            // the stack rather than around `content`, so no wrapper stands between the lazy stack
            // and its slips; the header does not change with the phase.
            .ateAnimation(AteMotion.fillIn, value: store.phase)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            async let cities: Void? = area?.loadCities()
            await store.refresh()
            _ = await cities
        }
        // The title and the area slide away on the way down and come back on the way up.
        // A new area starts at the top too.
        .ateTabRootHeader(scrollToTop: scrollToTopSignal + scrollToTopAfterArea) { header }
        .task {
            onViewed()
            // The first page works near me out itself (`FeedAreaModel.cityForFirstPage`).
            await store.loadIfNeeded()
            #if DEBUG
            if JournalDebugLaunch.opensFeedLocation { isChoosingArea = true }
            #endif
        }
        // Read ahead, so the location sheet rises with its cities in it (#83's rule) — they move
        // with the feed's own refresh, not on every open.
        .task { await area?.loadCitiesIfNeeded() }
        .ateSheet(isPresented: $isChoosingArea, name: "feed_location",
                  prepare: { await area?.loadCitiesIfNeeded() }, content: {
            if let area {
                FeedLocationSheet(model: area) { choice in
                    Task { await choose(choice, in: area) }
                }
            }
        })
    }

    // MARK: - Where

    /// A pick from the sheet. Near me picked again is a retry — the phone may have moved, or the
    /// last read failed — so it reads again even when the city looks the same.
    private func choose(_ choice: FeedLocation, in area: FeedAreaModel) async {
        let changed = area.choose(location: choice)
        guard changed || choice == .nearMe else { return }
        scrollToTopAfterArea += 1
        await store.reload()
    }

    private static let topAnchor = "feed.top"
    /// `padding:62px 12px 10px` under a 40 title: where the slips — or an empty state — begin.
    private static let headerBottom: CGFloat = 62 + 40 + AteMetrics.feedHeaderBottom

    /// `padding:62px 12px 10px` (`FeedTight`) — the screen's name, and where it is about.
    private var header: some View {
        FeedLocationHeader(model: area) { isChoosingArea = true }
            .padding(.horizontal, AteMetrics.listGutter)
            .ateContentTop(62)
            .padding(.bottom, AteMetrics.feedHeaderBottom)
            .id(Self.topAnchor)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            SlipSkeleton(hasByline: true)
                .ateCardWidth()
                .transition(.opacity)
        case .empty:
            // Honest: nobody else has written anything yet. Not an error, and not an instruction.
            AteEmptyState(title: "Nobody's written\nanything yet.")
                .ateEmptyPlacement(top: Self.headerBottom)
        case .signedOut:
            AteEmptyState(title: "Nobody's\nsigned in.")
                .ateEmptyPlacement(top: Self.headerBottom)
        case .failed:
            AteUnreachableState { Task { await store.refresh() } }
                .ateEmptyPlacement(top: Self.headerBottom)
        case .ready:
            slips
                .transition(.opacity)
        }
    }

    /// The slips, as rows of the page's own lazy stack (see `body`): each `feedSlipGap` under the
    /// one before it, at the card width.
    @ViewBuilder
    private var slips: some View {
        ForEach(store.entries) { entry in
            EntrySlip(
                slip: EntrySlipPresentation.feed(entry),
                onOpen: { onOpen(entry) },
                onProfile: { onProfile(entry.authorID) },
                onSave: { onSave(entry, $0) },
                onPlace: onPlace,
                onDish: { onDish($0.dishID) },
                identifier: "feed.slip"
            )
            .task { await store.loadMoreIfNeeded(after: entry) }
            // Its own task, so the row scrolling away cancels the prefetch with it.
            .task { await AtePrefetch.photos(after: entry, in: store.entries) }
            .padding(.top, entry.id == store.entries.first?.id ? 0 : AteMetrics.feedSlipGap)
            .ateCardWidth()
        }
        if let message = store.inlineErrorMessage {
            Text(message)
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, AteMetrics.regular)
                .padding(.top, store.entries.isEmpty ? 0 : AteMetrics.feedSlipGap)
                .ateCardWidth()
        }
    }
}

#if DEBUG
#Preview("Feed") {
    let social = InMemorySocialService()
    return FeedScreen(store: EntryListStore(fallbackMessage: "Couldn't load the feed.") { cursor, size in
        try await social.feedPage(after: cursor, pageSize: size, includeOwn: false)
    })
    .ateGround()
}
#endif
