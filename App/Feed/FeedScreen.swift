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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .refreshable { await store.refresh() }
        // The title and the area slide away on the way down and come back on the way up.
        // A new area starts at the top too.
        .ateTabRootHeader(scrollToTop: scrollToTopSignal + scrollToTopAfterArea) { header }
        .task {
            onViewed()
            await store.loadIfNeeded()
        }
        .sheet(isPresented: $isChoosingArea) {
            if let area {
                FeedAreaSheet(model: area) { choice in
                    guard area.choose(choice) else { return }
                    scrollToTopAfterArea += 1
                    Task { await store.reload() }
                }
            }
        }
    }

    private static let topAnchor = "feed.top"
    /// `padding:62px 12px 10px` under a 40 title: where the slips — or an empty state — begin.
    private static let headerBottom: CGFloat = 62 + 40 + AteMetrics.feedHeaderBottom

    /// `padding:62px 12px 10px` (`FeedTight`) — the screen's name, and the area it is about. The
    /// pill opens the area sheet; "Everywhere" until the reader picks one.
    private var header: some View {
        // At the accessibility sizes the area pill goes under the title rather than breaking
        // "Everywhere" mid-word beside it.
        let stacks = dynamicTypeSize.isAccessibilitySize
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AteMetrics.snug))
            : AnyLayout(HStackLayout())
        return layout {
            Text("Feed").ateTextLine(.screenTitle)
            if stacks == false { Spacer(minLength: AteMetrics.snug) }
            AteChip(
                icon: .place,
                title: area?.selected ?? "Everywhere",
                height: 40,
                action: area == nil ? nil : { isChoosingArea = true }
            )
            .accessibilityLabel("Area")
            .accessibilityValue(area?.selected ?? "Everywhere")
            .accessibilityIdentifier("feed.area")
        }
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
