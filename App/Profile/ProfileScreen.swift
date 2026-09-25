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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .ateGround()
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .refreshable { await store.refresh() }
        .task {
            await store.load()
            if case .ready(let summary) = store.header { onViewed(summary.isMe) }
        }
        .sheet(isPresented: $isShowingActions) { actions }
    }

    // MARK: - Bands

    /// `padding:60px 12px 0` — back, and the one "…" that carries everything you can do about a
    /// person (design rule 1: icons before labels).
    private var topBar: some View {
        HStack(spacing: 0) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            // Only for somebody else: there is no reporting or blocking yourself, and Search will
            // push your own page soon enough.
            if store.isSomebodyElse {
                AteIconButton(icon: .more, label: "More", size: 22) { isShowingActions = true }
            }
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    @ViewBuilder
    private var header: some View {
        switch store.header {
        case .loading:
            ProfileHeaderSkeleton()
                .padding(.horizontal, AteMetrics.listGutter)
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
                .padding(.horizontal, AteMetrics.listGutter)
        case .empty:
            // Nothing public. Not an error, and not an invitation to do anything about it.
            AteEmptyState(title: "Nothing\nto read yet.")
        case .signedOut:
            AteEmptyState(title: "Nobody's\nsigned in.")
        case .failed(let message):
            AteEmptyState(title: message)
        case .ready:
            slips
        }
    }

    private var slips: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
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
            }
        }
        .padding(.horizontal, AteMetrics.listGutter)
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
                        if await store.report() { onReported() }
                    }
                },
                onBlock: {
                    Task {
                        guard await store.block() else { return }
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

/// Where a shared profile points. A placeholder host until the real one is registered — the link is
/// the artefact, and it is built in one place so the day the domain lands it changes once.
enum ProfileShare {
    static func link(for handle: String) -> URL? {
        URL(string: "https://ate.app/@\(handle)")
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
