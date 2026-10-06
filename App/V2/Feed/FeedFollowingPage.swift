import AteKit
import SwiftUI

/// **What you follow** (`discover.html`, 4 Oct) — pushed from the row at the end of the Feed's edition,
/// and the only door to the list: the followed categories in shelf order, each with its #1 dish. A tap
/// opens the category's page, a swipe unfollows, a long-press drag reorders the shelves. Nothing else
/// on the page.
struct FeedFollowingPage: View {
    let city: String?
    let context: V2PageContext

    @State private var store: FollowingStore
    @State private var isCollapsed = false

    init(city: String?, context: V2PageContext) {
        self.city = city
        self.context = context
        _store = State(initialValue: FollowingStore(
            reads: context.services.feedEdition, city: city, analytics: context.services.analytics
        ))
    }

    var body: some View {
        List {
            AtePageTitle(title: FeedEditionCopy.following, isLong: true)
                .plainRow()
            switch store.phase {
            case .loading:
                ForEach(0..<FeedFollowingMetrics.skeletonRows, id: \.self) { index in
                    AteFollowRowSkeleton(isFirst: index == 0).plainRow()
                }
            case .failed(let message):
                AteEmptyState(line: message, art: .torn, pill: (title: "Try again", action: retry))
                    .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
                    .plainRow()
                    .accessibilityIdentifier("state.unreachable")
            case .ready:
                if store.rows.isEmpty {
                    AteEmptyState(line: FeedFollowingCopy.empty, art: .rail)
                        .containerRelativeFrame(.vertical) { height, _ in height * FeedEditionCopy.emptyShare }
                        .plainRow()
                        .accessibilityIdentifier("state.empty")
                } else {
                    rows
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.tabBarScrollInset, for: .scrollContent)
        .atePageCollapse($isCollapsed)
        .ateGround()
        .ateCollapsingTitle(FeedEditionCopy.following, isCollapsed: isCollapsed)
        .refreshable { await store.refresh() }
        .task { await store.loadIfNeeded() }
        .accessibilityIdentifier("following.page")
    }

    private var rows: some View {
        let letters = DishLetter.neighbourly(store.rows.map { ($0.tileID, $0.top?.name ?? $0.craving.title) })
        return ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
            AteFollowRow(
                photo: .dish(letters[index], cover: row.top?.coverURLString),
                name: row.craving.title,
                isFirst: index == 0,
                identifier: "following.\(row.craving.slug)"
            ) {
                context.open(.tag(row.craving.route(city: city)), from: .feed)
            }
            .plainRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(FeedFollowingCopy.unfollow, role: .destructive) {
                    Task { await store.unfollow(row.id) }
                }
                .tint(AteColor.destructive)
            }
            .accessibilityAction(named: FeedFollowingCopy.unfollow) {
                Task { await store.unfollow(row.id) }
            }
        }
        .onMove { source, destination in
            Task { await store.move(fromOffsets: source, toOffset: destination) }
        }
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

private extension View {
    /// A row of the page's plain list: edge to edge on the ground, no system separator (the rows draw
    /// their own hairline).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum FeedFollowingCopy {
    static let empty = "Nothing\nfollowed yet."
    static let unfollow = "Unfollow"
}

enum FeedFollowingMetrics {
    static let skeletonRows = 4
}
