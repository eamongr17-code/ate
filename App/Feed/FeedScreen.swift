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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                }
                .padding(.bottom, AteMetrics.tabBarScrollInset)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
        .task {
            onViewed()
            await store.loadIfNeeded()
        }
    }

    private static let topAnchor = "feed.top"

    /// `padding:62px 12px 14px` — the screen's name, and the city it is about.
    private var header: some View {
        HStack {
            Text("Feed").ateTextLine(.screenTitle)
            Spacer(minLength: AteMetrics.snug)
            // Static: Melbourne is the launch market, and a chip that could be changed would be a
            // promise of a second city we are not making (PRODUCT.md — density beats breadth).
            AteChip(icon: .place, title: "Melbourne", height: 40)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .ateContentTop(62)
        .padding(.bottom, AteMetrics.slipGap)
        .id(Self.topAnchor)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            SlipSkeleton(hasByline: true)
                .padding(.horizontal, AteMetrics.listGutter)
        case .empty:
            // Honest: nobody else has written anything yet. Not an error, and not an instruction.
            AteEmptyState(title: "Nobody's written\nanything yet.")
                .padding(.top, AteMetrics.snug)
        case .signedOut:
            AteEmptyState(title: "Nobody's\nsigned in.")
                .padding(.top, AteMetrics.snug)
        case .failed(let message):
            AteEmptyState(title: message)
                .padding(.top, AteMetrics.snug)
        case .ready:
            slips
        }
    }

    private var slips: some View {
        LazyVStack(alignment: .leading, spacing: AteMetrics.slipGap) {
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
            }
            if let message = store.inlineErrorMessage {
                Text(message)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AteMetrics.regular)
            }
        }
        .padding(.horizontal, AteMetrics.listGutter)
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
