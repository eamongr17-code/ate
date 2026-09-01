import AteKit
import SwiftUI

/// The Diary tab: everything **you** have logged, newest first.
///
/// The same shape as the feed by design — a `List` of ``DishCard``s in a `NavigationStack`, with all
/// of the loading/paging/state rules in ``DiaryStore`` and none of them here. The differences are
/// the ones a person would name: the byline is replaced by the date (`.diary` card mode — you know
/// who wrote it), and the empty state is an invitation to log rather than a report that the world is
/// quiet.
///
/// No edit or delete affordances: V1 has no review-mutation path (PRODUCT.md), and offering a
/// context menu that can't do anything is worse than offering none.
struct DiaryView: View {
    @State private var store: DiaryStore
    @State private var path = NavigationPath()

    /// How this stack builds detail screens — the app's one API client, or fixtures in previews.
    private let detail: DetailContext
    /// Presents the Log sheet. Nil in previews and any host that hasn't wired it; the empty state
    /// simply loses its button rather than showing one that does nothing.
    private let onLogDish: (@MainActor () -> Void)?
    /// The staging-only sign-in affordance until the real auth flow lands. Debug builds only.
    private let debugSignIn: DebugStagingSignIn?
    /// "Staging · Supabase cvoit…" — which backend this build is talking to, so a test drive can
    /// never mistake one environment for another. Nil in Release, where it must not appear.
    private let environmentFootnote: String?

    init(
        store: DiaryStore,
        detail: DetailContext,
        onLogDish: (@MainActor () -> Void)? = nil,
        debugSignIn: DebugStagingSignIn? = nil,
        environmentFootnote: String? = nil
    ) {
        _store = State(initialValue: store)
        self.detail = detail
        self.onLogDish = onLogDish
        self.debugSignIn = debugSignIn
        self.environmentFootnote = environmentFootnote
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Diary")
                .toolbar { environmentStamp }
                // Registered once, at this stack's root: every dish and restaurant reached from the
                // diary — including onward pushes inside detail — resolves here as `source: .diary`.
                .detailDestinations(source: .diary, context: detail)
        }
        // On the stack rather than on its content, so a push-then-pop within the tab is not a new
        // "view". This fires on each *tab* appearance, which is what makes a review posted in the
        // Log sheet show up here without an app restart (the store marks itself stale on post).
        .onAppear {
            store.recordDiaryViewed()
            Task { await store.loadIfNeeded() }
        }
    }

    /// Debug builds only, by construction: the host passes nil in Release, so there is no build
    /// where this can leak into a shipped bar.
    @ToolbarContentBuilder
    private var environmentStamp: some ToolbarContent {
        if let environmentFootnote {
            ToolbarItem(placement: .topBarTrailing) {
                Text(environmentFootnote)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            loadingList
        case .ready:
            diaryList
        case .empty:
            empty
        case .signedOut:
            signedOut
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load your diary", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.retry() } }
            }
        }
    }

    // MARK: - States

    /// Redacted real cards, not a spinner: the list is already the right shape when content lands.
    private var loadingList: some View {
        List(FeedPlaceholder.entries(count: 4)) { entry in
            DishCard(model: DishCardModel(entry), mode: .diary)
                .diaryRow()
        }
        .listStyle(.plain)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading your diary")
    }

    private var diaryList: some View {
        List {
            ForEach(store.entries) { entry in
                Button {
                    store.recordTap(on: entry)
                    path.append(entry.dishRoute)
                } label: {
                    DishCard(model: DishCardModel(entry), mode: .diary)
                }
                .buttonStyle(.plain)
                .diaryRow()
                .task { await store.loadMoreIfNeeded(after: entry) }
            }

            if store.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.regular)
                    .listRowSeparator(.hidden)
            }

            if let message = store.inlineErrorMessage {
                inlineError(message)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
    }

    /// An invitation, not an error: nothing is wrong, there is simply nothing here yet.
    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing logged yet", systemImage: "book.closed")
        } description: {
            Text("Rate a dish and it lands here — your own record of what's worth ordering.")
        } actions: {
            if let onLogDish {
                Button("Log a dish", action: onLogDish)
            }
        }
        .refreshableEmptyState { await store.refresh() }
    }

    /// Signed out is NOT the empty state. RLS answers an anonymous read with a successful empty
    /// page, so without this screen we would tell a stranger that *they* had logged nothing.
    private var signedOut: some View {
        ContentUnavailableView {
            Label("Sign in to see your diary", systemImage: "person.crop.circle")
        } description: {
            Text("Everything you log is kept here, newest first.")
        } actions: {
            if let debugSignIn {
                Button(debugSignIn.title) {
                    Task {
                        await debugSignIn.signIn()
                        await store.retry()
                    }
                }
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.snug) {
            Text(message)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            Button("Try again") { Task { await store.loadMore() } }
                .font(Theme.Text.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.regular)
        .listRowSeparator(.hidden)
    }
}

private extension View {
    /// A card in a list: the card draws its own surface, so the row must not draw one too, and the
    /// system separator would cut between two already-separate cards.
    func diaryRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.snug,
                leading: Theme.Spacing.comfortable,
                bottom: Theme.Spacing.snug,
                trailing: Theme.Spacing.comfortable
            ))
    }

    /// `.refreshable` needs a scroll view to hang off; an empty state has none.
    func refreshableEmptyState(action: @escaping () async -> Void) -> some View {
        ScrollView {
            self.containerRelativeFrame(.vertical)
        }
        .refreshable { await action() }
    }
}

#if DEBUG
#Preview("Diary") {
    DiaryView(
        store: DiaryStore(client: PreviewDiaryClient(), pageSize: 4),
        detail: DetailContext(dataSource: PreviewDetailDataSource(), analytics: DetailTelemetry.none)
    )
}

/// Preview-only backend: the placeholder entries, paged.
private struct PreviewDiaryClient: DiaryReading {
    func diaryPage(_ request: PageRequest) async throws -> Page<FeedEntry> {
        Page(items: FeedPlaceholder.entries(count: request.limit), nextCursor: nil)
    }
}
#endif
