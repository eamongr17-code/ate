import AteKit
import SwiftUI

/// **`Profile`** — somebody else's record: who they are, what they have eaten, and their entries.
///
/// The same slip as the feed, without the byline (the page is already their name) and with the age
/// at the right of the foot line, where the journal prints its date. Every dish still carries its
/// bookmark: a profile is a place you come to for what to order next, exactly like the feed.
struct ProfileScreen: View {
    let store: ProfileStore
    var onOpen: (EntryCard) -> Void = { _ in }
    var onSave: (EntryCard, AteSlip.Dish) -> Void = { _, _ in }
    /// A slip's pin line and its dish rows.
    var onPlace: (UUID) -> Void = { _ in }
    var onDish: (UUID) -> Void = { _ in }
    /// Blocked: the page is done. The caller pops it and refetches whatever is behind it.
    var onBlocked: () -> Void = {}
    var onViewed: (Bool) -> Void = { _ in }
    var onReported: () -> Void = {}

    @State private var isShowingActions = false
    /// A report or block that did not happen, said once (``ActionFailure``).
    @State private var failure: ActionFailure?

    var body: some View {
        ScrollView {
            // The header and the entries are two reads. Until both have answered the whole page is
            // its skeleton — the header's shape over the slips' — and then it fills in once, rather
            // than a name popping in over a list that is still coming (round 4).
            //
            // The page is one lazy stack and every slip is one of its own rows, 18 under the band
            // above it — never a `LazyVStack` of slips inside a `VStack` under the header, which is
            // the shape that locked the Feed's main thread for minutes (`FeedScreen`).
            LazyVStack(alignment: .leading, spacing: 0) {
                if isSettled {
                    header
                        .transition(.opacity)
                    content
                        .padding(.top, Self.bandGap)
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: Self.bandGap) {
                        ProfileHeaderSkeleton().ateCardWidth()
                        SlipSkeleton().ateCardWidth()
                    }
                    .transition(.opacity)
                }
            }
            .ateAnimation(AteMotion.fillIn, value: isSettled)
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        // The glass back button, and "…" in glass — only for somebody else: there is no
        // reporting or blocking yourself (round 4).
        .ateNavigationBar(trailing: {
            if store.isSomebodyElse {
                AteIconButton(icon: .more, label: "More", size: 22) { isShowingActions = true }
            }
        })
        .refreshable { await store.refresh() }
        .task {
            await store.load()
            if case .ready(let summary) = store.header { onViewed(summary.isMe) }
        }
        .sheet(isPresented: $isShowingActions) { actions }
        .ateFailureAlert($failure)
    }

    /// Both reads have answered, whichever way.
    private var isSettled: Bool {
        store.header != .loading && store.entries.phase != .loading
    }

    // MARK: - Bands

    @ViewBuilder
    private var header: some View {
        switch store.header {
        case .loading:
            ProfileHeaderSkeleton()
                .ateCardWidth()
        case .unavailable:
            // A blocked or deleted author is simply not there (contract). Say that, and nothing else.
            AteEmptyState(title: "This person\nisn't here.")
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 18) {
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
                        if let city = summary.city {
                            Text(city)
                                .ateText(.meta)
                                .foregroundStyle(AtePalette.automatic.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                AteStatsSlip(cells: [
                    (summary.orders.formatted(), "Orders"),
                    (summary.places.formatted(), "Places"),
                    (summary.dishes.formatted(), "Dishes")
                ])
            }
            .padding(.horizontal, AteMetrics.listGutter)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.entries.phase {
        case .loading:
            SlipSkeleton()
                .ateCardWidth()
        case .empty:
            // Nothing public. Not an error, and not an invitation to do anything about it.
            AteEmptyState(title: "Nothing\nto read yet.")
        case .signedOut:
            AteEmptyState(title: "Nobody's\nsigned in.")
        case .failed:
            AteUnreachableState { Task { await store.refresh() } }
        case .ready:
            slips
        }
    }

    /// `gap:18px` — between the header and the slips, and between one slip and the next.
    private static let bandGap: CGFloat = 18

    /// The slips, as rows of the page's own lazy stack (see `body`). Each is ``bandGap`` under the
    /// band before it — the header, or the slip above — from the padding `body` gives `content`,
    /// which a `ForEach` hands to every row.
    private var slips: some View {
        ForEach(store.entries.entries) { entry in
            EntrySlip(
                slip: EntrySlipPresentation.profile(entry),
                onOpen: { onOpen(entry) },
                onSave: { onSave(entry, $0) },
                onPlace: onPlace,
                onDish: { onDish($0.dishID) },
                identifier: "profile.slip"
            )
            .task { await store.entries.loadMoreIfNeeded(after: entry) }
            // Its own task, so the row scrolling away cancels the prefetch with it.
            .task { await AtePrefetch.photos(after: entry, in: store.entries.entries) }
            .ateCardWidth()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if store.isSomebodyElse, let handle = store.username {
            AteActionsSheet(
                title: "@\(handle)",
                blockTitle: "Block @\(handle)",
                onSavePlace: nil,
                onShare: { ProfileShare.link(for: handle).map { [$0] } ?? [] },
                onReport: {
                    Task {
                        if await store.report() { onReported() } else { failure = .report }
                    }
                },
                onBlock: {
                    Task {
                        guard await store.block() else {
                            failure = .block
                            return
                        }
                        onBlocked()
                    }
                }
            )
        }
    }
}

/// The header before it has arrived — the shape of a name, not a spinner.
private struct ProfileHeaderSkeleton: View {
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

/// Where a shared profile points — off the app's one domain constant (``AteLegal/site``), which is
/// still a placeholder until Eamon registers the real one.
enum ProfileShare {
    static func link(for handle: String) -> URL? {
        AteLegal.profile(handle: handle)
    }
}

#if DEBUG
#Preview("Profile") {
    let social = InMemorySocialService()
    return NavigationStack {
        ProfileScreen(store: ProfileStore(userID: InMemorySocialService.Seed.jess, profiles: social))
    }
}
#endif
