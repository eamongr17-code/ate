import AteKit
import SwiftUI

/// **The Lists shelf** (`lists-playlists.html`, approved 9 Oct) — your lists under Journal |
/// Lists, newest made first, as a two-column grid of covers like a music library's playlists,
/// after the dashed New list tile (always first, empty shelf included). New list (that tile, or the
/// glass group's list-plus) names one, opens its page and raises the picker
/// over it. Pull to refresh; the shelf pages as it nears its end.
struct ListsShelf: View {
    let app: AppModel
    let router: TabRouter<JournalStores>
    @Binding var isCollapsed: Bool
    @Binding var isNaming: Bool

    /// The new list, once named: its page opens as the name sheet goes.
    @State private var opening: ListRoute?

    private var lists: ListsStore { app.lists }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: AteListCoverMetrics.rowGap) {
                tiles
            }
            .padding(.horizontal, AteListCoverMetrics.gutter)
            .padding(.top, AteMetrics.snug)
            .padding(.bottom, AteMetrics.section)
            .ateAnimation(AteMotion.fillIn, value: lists.phase)
            band
        }
        .scrollIndicators(.hidden)
        .ateRootCollapse($isCollapsed)
        .refreshable { await lists.refresh() }
        .task { await lists.loadIfNeeded() }
        .accessibilityIdentifier("lists.shelf")
        .sheet(isPresented: $isNaming, onDismiss: openMade) {
            ListNameSheet(title: ListsCopy.newList, initial: "") { name in
                // The server's own id, so the page reads the list it opens (C2 → C4, C3 over it).
                guard let made = await lists.create(name: name) else { return false }
                opening = ListRoute(made, picksOnOpen: true)
                return true
            }
        }
        .listsFailureAlert(failure: lists.failure) { lists.clearFailure() }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AteListCoverMetrics.columnGap, alignment: .top), count: 2)
    }

    @ViewBuilder
    private var tiles: some View {
        AteNewListTile(title: ListsCopy.newList, identifier: "lists.newCard") {
            guard app.gate.permitsWrite(.journal) else { return }
            app.services.analytics(ListEvents.ctaTapped(from: .shelf))
            isNaming = true
        }
        switch lists.phase {
        case .loading:
            ForEach(0..<ListsMetrics.skeletonCards, id: \.self) { _ in
                AteListTileSkeleton()
            }
            .transition(.opacity)
        case .empty, .failed:
            EmptyView()
        case .ready:
            let accents = DishTileIdentity.paletteIndices(for: lists.lists.map(\.id), count: AteListCover.accents.count)
            ForEach(Array(lists.lists.enumerated()), id: \.element.id) { index, list in
                AteListTile(
                    id: list.id,
                    name: list.name,
                    count: list.itemCount,
                    covers: list.covers,
                    isPending: lists.isPending(list),
                    accentIndex: accents[index],
                    identifier: "lists.card"
                ) {
                    router.open(.list(ListRoute(list)), from: .journal)
                }
                .task { await lists.loadMoreIfNeeded(after: list) }
            }
        }
    }

    /// Under the New list tile when there is nothing to show beside it.
    @ViewBuilder
    private var band: some View {
        switch lists.phase {
        case .empty:
            AteEmptyState(line: ListsCopy.emptyShelf, art: .lists)
                .frame(minHeight: ListsMetrics.emptyMinimum)
        case .failed:
            AteEmptyState(line: ListsCopy.unreachable, art: .torn, pill: (ListsCopy.tryAgain, { retry() }))
                .frame(minHeight: ListsMetrics.emptyMinimum)
        case .loading, .ready:
            EmptyView()
        }
    }

    private func openMade() {
        guard let route = opening else { return }
        opening = nil
        router.open(.list(route), from: .journal)
    }

    private func retry() {
        Task { await lists.refresh() }
    }
}

extension ListStore: @retroactive Identifiable {
    public var id: UUID { listID }
}

extension View {
    /// **A list refusal, said once** — the app's standard alert: one line and OK. A cap is explained;
    /// anything the network lost is "Couldn't reach Ate."; a list already gone says nothing.
    func listsFailureAlert(failure: ListsError?, clear: @escaping () -> Void) -> some View {
        let title = failure.flatMap(ListsCopy.failure) ?? ""
        return alert(
            title,
            isPresented: Binding(
                get: { failure.flatMap(ListsCopy.failure) != nil },
                set: { if $0 == false { clear() } }
            )
        ) {
            Button("OK", role: .cancel) { clear() }
        }
        .onChange(of: failure) { _, now in
            // A refusal with nothing to say is cleared at once, so the next one can be heard.
            if let now, ListsCopy.failure(now) == nil { clear() }
        }
    }
}
