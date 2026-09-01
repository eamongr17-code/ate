import AteKit
import SwiftUI

/// The home tab: one global, reverse-chronological stream of everybody's reviews.
///
/// The view is intentionally thin — every rule about what to load, when, and what state that puts
/// the screen in lives in ``FeedStore`` (and is unit-tested there). What's left here is a stock
/// `List` in a `NavigationStack`: system pull-to-refresh, system empty states, system navigation.
///
/// Anti-goal, from strategy: nothing here optimises session length. No infinite auto-play, no
/// engagement chrome, no like/comment affordances (V3). Reviews, newest first, and a way out to the
/// dish.
struct FeedView: View {
    @State private var store: FeedStore
    @State private var path = NavigationPath()

    /// The staging-only sign-in affordance until the real auth flow lands. Debug builds only.
    private let debugSignIn: DebugStagingSignIn?

    init(store: FeedStore, debugSignIn: DebugStagingSignIn? = nil) {
        _store = State(initialValue: store)
        self.debugSignIn = debugSignIn
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Feed")
                .navigationDestination(for: DishRoute.self) { route in
                    DishDestinationPlaceholder(route: route)
                }
        }
        .task {
            store.recordFeedViewed()
            if let debugSignIn, debugSignIn.isAutoSignInRequested {
                await debugSignIn.signIn()
            }
            await store.loadFirstPageIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            loadingList
        case .ready:
            feedList
        case .empty:
            ContentUnavailableView(
                "No reviews yet",
                systemImage: "fork.knife",
                description: Text("When anyone rates a dish, it shows up here.")
            )
            .refreshableEmptyState { await store.refresh() }
        case .signedOut:
            signedOut
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load the feed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.retry() } }
            }
        }
    }

    // MARK: - States

    /// Redacted real rows, not a spinner: the list is already the right shape when content lands,
    /// so nothing reflows and the eye stays where it was.
    private var loadingList: some View {
        List(FeedPlaceholder.entries(count: 6)) { entry in
            FeedRow(entry: entry)
        }
        .listStyle(.plain)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading the feed")
    }

    private var feedList: some View {
        List {
            ForEach(store.entries) { entry in
                Button {
                    store.recordTap(on: entry)
                    path.append(entry.dishRoute)
                } label: {
                    FeedRow(entry: entry)
                }
                .buttonStyle(.plain)
                .task { await store.loadMoreIfNeeded(after: entry) }
            }

            if store.isLoadingMore {
                loadingMoreRow
            }

            // A page that failed to load is a footnote under the content — never an alert, which
            // would interrupt a scroll to report something the next scroll retries anyway.
            if let message = store.inlineErrorMessage {
                inlineError(message)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
    }

    private var loadingMoreRow: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.regular)
            .listRowSeparator(.hidden)
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

    /// Signed out is NOT the empty state. RLS answers an anonymous read with a successful empty
    /// page, so without this screen a signed-out user would be told nobody has ever posted.
    private var signedOut: some View {
        ContentUnavailableView {
            Label("Sign in to see the feed", systemImage: "person.crop.circle")
        } description: {
            Text("Ate shows what everyone is ordering. Sign in to join in.")
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
}

/// Stand-in destination so the feed's navigation is real and drivable before the Dish detail build
/// lands. The route value (``DishRoute``) is the contract; the lead swaps this one view for the
/// real screen at merge.
private struct DishDestinationPlaceholder: View {
    let route: DishRoute

    var body: some View {
        ContentUnavailableView(
            "Dish detail",
            systemImage: "fork.knife.circle",
            description: Text("Arriving with the detail build.\n\(route.dishID.uuidString)")
        )
        .navigationTitle("Dish")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    /// `.refreshable` needs a scroll view to hang off; an empty state has none. Wrapping it in a
    /// `ScrollView` keeps pull-to-refresh working on the empty feed, which is the one screen where
    /// a user most wants to pull.
    func refreshableEmptyState(action: @escaping () async -> Void) -> some View {
        ScrollView {
            self.containerRelativeFrame(.vertical)
        }
        .refreshable { await action() }
    }
}
