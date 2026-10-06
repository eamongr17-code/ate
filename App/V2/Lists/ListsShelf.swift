import AteKit
import SwiftUI

/// **The Lists shelf** (`lists-notifications.html` §3, colour cards) — your lists under Journal |
/// Lists, newest made first, one full-width card each, under the dashed New list card (always first,
/// empty shelf included). New list (that card, or the glass group's list-plus) names one, opens its
/// page and raises the picker over it. Pull to refresh; the shelf pages as it nears its end.
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
            LazyVStack(spacing: AteListCardMetrics.spacing) {
                content
            }
            .padding(.horizontal, AteMetrics.listGutter)
            .padding(.top, AteMetrics.snug)
            .padding(.bottom, AteMetrics.section)
            .ateAnimation(AteMotion.fillIn, value: lists.phase)
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

    @ViewBuilder
    private var content: some View {
        AteNewListCard(title: ListsCopy.newList, identifier: "lists.newCard") {
            guard app.gate.permitsWrite(.journal) else { return }
            app.services.analytics(ListEvents.ctaTapped(from: .shelf))
            isNaming = true
        }
        switch lists.phase {
        case .loading:
            ForEach(0..<ListsMetrics.skeletonCards, id: \.self) { _ in
                AteListCardSkeleton()
            }
            .transition(.opacity)
        case .empty:
            emptyBand(AteEmptyState(line: ListsCopy.emptyShelf))
        case .failed:
            emptyBand(AteEmptyState(line: ListsCopy.unreachable, pill: (ListsCopy.tryAgain, { retry() })))
        case .ready:
            let accents = DishTileIdentity.paletteIndices(for: lists.lists.map(\.id), count: AteListCard.accents.count)
            ForEach(Array(lists.lists.enumerated()), id: \.element.id) { index, list in
                AteListCard(
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

    private func emptyBand(_ state: AteEmptyState) -> some View {
        // The band fills what the New list card leaves of the screen.
        state.containerRelativeFrame(.vertical) { length, _ in
            max(length - AteNewListCardMetrics.height - AteListCardMetrics.spacing, ListsMetrics.emptyMinimum)
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
