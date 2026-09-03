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

    /// How this stack builds detail screens. Injected rather than defaulted so the feed tab shares
    /// the app's one API client (and so previews can run on fixtures).
    private let detail: DetailContext

    init(
        store: FeedStore,
        detail: DetailContext,
        debugSignIn: DebugStagingSignIn? = nil
    ) {
        _store = State(initialValue: store)
        self.detail = detail
        self.debugSignIn = debugSignIn
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Feed")
                // Registered once, at this stack's root: every dish and restaurant reached from the
                // feed — including onward pushes inside detail — resolves here as `source: .feed`.
                .detailDestinations(source: .feed, context: detail)
                // Rule R's other half: every restaurant name in this stack, at any depth, pushes
                // through here (§5).
                .stackRouting(path: $path, analytics: detail.analytics)
        }
        .task {
            store.recordFeedViewed()
            // The feed is fetched when it is *visited*, never at launch — the Diary is the launch
            // tab. (Debug auto sign-in used to live here; it now runs in `RootTabView` so a launch
            // that lands on the Diary is signed in too.)
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
        List(FeedPlaceholder.entries(count: 4)) { entry in
            DishCard(model: DishCardModel(entry), mode: .feed)
                .feedRow()
        }
        .listStyle(.plain)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading the feed")
    }

    private var feedList: some View {
        List {
            ForEach(store.entries) { entry in
                card(for: entry)
                    .feedRow()
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

    // MARK: - The row

    /// One review, as the app's one dish card (§2 — `FeedRow` is gone; two renderings of one review
    /// is the legacy failure this codebase exists to avoid).
    ///
    /// **The nested tap targets are the load-bearing part (§5).** The row's own tap is an
    /// `onTapGesture` on a `contentShape`'d container, *not* an outer `Button`: an outer button
    /// consumes every touch inside its bounds, so the restaurant link in the place line would never
    /// fire. Two flat siblings, not a button inside a button.
    ///
    /// VoiceOver can't discover a nested target by geometry, so the card is presented as one element
    /// with a written label, a default action (open the dish) and a custom action (open the
    /// restaurant) — the same two things the context menu offers a sighted user.
    private func card(for entry: FeedEntry) -> some View {
        DishCard(model: DishCardModel(entry), mode: .feed)
            .contentShape(.rect)
            .onTapGesture { openDish(entry) }
            .contextMenu {
                Button("Open dish", systemImage: "fork.knife") { openDish(entry) }
                Button("Open \(entry.restaurant.name)", systemImage: "building.2") {
                    openRestaurant(entry)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: entry))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openDish(entry) }
            .accessibilityAction(named: "Open \(entry.restaurant.name)") { openRestaurant(entry) }
    }

    private func openDish(_ entry: FeedEntry) {
        store.recordTap(on: entry)
        path.append(entry.dishRoute)
    }

    private func openRestaurant(_ entry: FeedEntry) {
        detail.analytics(DiaryEvents.restaurantNameTapped(from: .feedRow))
        path.append(RestaurantRoute(restaurantID: entry.restaurant.id))
    }

    /// Written rather than combined: a combined element reads the inner link's "Open …" label in the
    /// middle of the review, and a card is one thing to a screen reader even when it is six views.
    private func accessibilityLabel(for entry: FeedEntry) -> String {
        var parts = [
            entry.author?.handle ?? "Someone",
            entry.dish.name,
            [entry.restaurant.name, entry.restaurant.locality].compactMap { $0 }.joined(separator: ", "),
            "rated \(ScoreFormat.outOfFive(entry.review.score.value))"
        ]
        if let note = entry.review.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: ", ")
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

private extension View {
    /// A card in a list: the card draws its own surface, so the row must not draw one too, and the
    /// system separator would cut between two already-separate cards.
    func feedRow() -> some View {
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
