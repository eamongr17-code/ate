import AteKit
import SwiftUI

/// **Somebody else's page** — pushed from a byline. Their name is in the bar (avatar, handle, city as
/// the subtitle); under it their three totals and their slips, a bookmark on every dish, because a
/// profile is somewhere you come to for what to order next. ••• opens the one actions sheet: Share,
/// Report, Block, each write asking once. No follow, no follower counts (no social in V1).
struct V2ProfilePage: View {
    let userID: UUID
    let context: V2PageContext

    /// Held here, not made in the destination's builder, which runs again on every redraw.
    @State private var store: ProfileStore
    @State private var isShowingActions = false
    /// A report or block that did not happen, said once.
    @State private var failure: ActionFailure?
    @Environment(\.dismiss) private var dismiss

    init(userID: UUID, context: V2PageContext) {
        self.userID = userID
        self.context = context
        let services = context.services
        _store = State(initialValue: ProfileStore(
            userID: userID,
            profiles: services.profiles,
            savedDishes: services.savedDishes,
            deletions: services.entryDeletions
        ))
    }

    var body: some View {
        ScrollView {
            // One lazy stack, every slip its own row — never a lazy stack of slips inside a plain
            // stack under the header, the shape that once locked the Feed's main thread.
            LazyVStack(alignment: .leading, spacing: AteProfileHeaderMetrics.bandGap) {
                if isSettled {
                    content
                } else {
                    AteProfileStats(summary: nil)
                        .ateCardWidth()
                    AteSkeleton(kind: .entrySlip)
                        .ateCardWidth()
                }
            }
            .ateAnimation(AteMotion.fillIn, value: isSettled)
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("v2.profile")
        .ateGround()
        .ateInlineByline(byline, fallback: "")
        .toolbar {
            // Only for somebody else: there is no reporting or blocking yourself.
            if store.isSomebodyElse {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingActions = true } label: {
                        AteIcon.more.view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("profile.more")
                }
            }
        }
        .task {
            await store.load()
            if case .ready(let summary) = store.header {
                context.services.analytics(SocialEvents.profileViewed(isMe: summary.isMe))
            }
        }
        .sheet(isPresented: $isShowingActions) { actions }
        .ateFailureAlert($failure)
    }

    /// Both reads have answered, whichever way.
    private var isSettled: Bool {
        store.header != .loading && store.entries.phase != .loading
    }

    private var byline: AteInlineByline? {
        guard case .ready(let summary) = store.header else { return nil }
        return AteInlineByline(userID: summary.userID, handle: summary.username, subtitle: summary.city)
    }

    // MARK: - Bands

    @ViewBuilder
    private var content: some View {
        switch store.header {
        case .loading:
            EmptyView()
        case .unavailable:
            // A blocked or deleted author is simply not there. Say that, and nothing else.
            AteEmptyState(line: "This person\nisn't here.", art: .torn)
                .containerRelativeFrame(.vertical)
        case .ready(let summary):
            AteProfileStats(summary: summary)
                .ateCardWidth()
            entries
        }
    }

    @ViewBuilder
    private var entries: some View {
        switch store.entries.phase {
        case .loading:
            AteSkeleton(kind: .entrySlip)
                .ateCardWidth()
        case .empty:
            // Nothing public. Not an error, and not an invitation to do anything about it.
            AteEmptyState(line: "Nothing\nto read yet.", art: .rail)
                .containerRelativeFrame(.vertical) { height, _ in height / 2 }
        case .signedOut:
            AteEmptyState(line: "Nobody's\nsigned in.", art: .printer)
                .containerRelativeFrame(.vertical) { height, _ in height / 2 }
        case .failed:
            AteEmptyState(line: "Couldn't\nreach Ate.", art: .torn, pill: (title: "Try again", action: {
                Task { await store.refresh() }
            }))
            .containerRelativeFrame(.vertical) { height, _ in height / 2 }
        case .ready:
            ForEach(store.entries.entries) { entry in
                AteEntrySlip(
                    slip: EntrySlipPresentation.profile(entry),
                    surface: .profile,
                    onOpen: { context.open(.entry(entry), from: .profile) },
                    onSave: { dish in save(dish, in: entry) },
                    onPlace: { context.open(.place($0), from: .profile) },
                    onDish: { context.open(.dish($0.dishID), from: .profile) },
                    identifier: "profile.slip"
                )
                .task { await store.entries.loadMoreIfNeeded(after: entry) }
                // Its own task, so the row scrolling away cancels the prefetch with it.
                .task { await AtePrefetch.photos(after: entry, in: store.entries.entries) }
                .ateCardWidth()
            }
        }
    }

    private func save(_ dish: AteSlip.Dish, in entry: EntryCard) {
        Task {
            await context.saves.toggle(
                dishID: dish.dishID,
                entryID: entry.id,
                isSaved: dish.isSaved,
                source: .profile
            )
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if store.isSomebodyElse, let handle = store.username {
            AteActionsSheet(
                title: "@\(handle)",
                blockTitle: "Block @\(handle)",
                onShare: { AteLegal.profile(handle: handle).map { [$0] } ?? [] },
                onReport: {
                    Task {
                        if await store.report() {
                            context.services.analytics(SocialEvents.profileReported())
                        } else {
                            failure = .report
                        }
                    }
                },
                onBlock: {
                    Task {
                        guard await store.block() else {
                            failure = .block
                            return
                        }
                        context.services.analytics(SocialEvents.userBlocked())
                        // The page is done: back to wherever it was opened from.
                        dismiss()
                    }
                }
            )
            .environment(context.gate)
        }
    }
}
