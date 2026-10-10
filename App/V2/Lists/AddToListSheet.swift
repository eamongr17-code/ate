import AteKit
import SwiftUI

/// What the Add to a list sheet is about: one of your own dish lines, and how to draw it.
struct AddToListTarget: Identifiable {
    let line: DishLine
    let name: String
    var place: String?
    var score: Rating?
    var photoURL: String?

    var id: DishLine { line }
}

/// **Add to a list** (`lists-notifications.html` D2) — close, the title, the dish as context, then
/// your lists by name with a tick where one already holds it (no counts — Eamon, on the page). A tap
/// adds or takes it off at once; "New list" is the last row: the dish goes on the list it makes,
/// then this sheet closes and that list's page opens (`onOpenList`).
/// The pill counts the lists it went onto ("Add to 2 lists"), or says Done.
struct AddToListSheet: View {
    let target: AddToListTarget
    let app: AppModel
    /// A list made here, with the dish on it: pushed by the page that raised this sheet.
    var onOpenList: ((ListRoute) -> Void)?

    @State private var store: AddToListStore
    @State private var heldAtStart: Set<UUID>?
    @State private var isNaming = false
    @State private var opening: ListRoute?
    @Environment(\.dismiss) private var dismiss

    init(target: AddToListTarget, app: AppModel, onOpenList: ((ListRoute) -> Void)? = nil) {
        self.target = target
        self.app = app
        self.onOpenList = onOpenList
        _store = State(initialValue: AddToListStore(
            line: target.line, service: app.services.lists, shelf: app.lists, analytics: app.services.analytics
        ))
    }

    /// Lists this sheet put the dish on.
    private var added: Int {
        let held = heldAtStart ?? []
        return store.lists.filter { $0.contains && held.contains($0.listID) == false }.count
    }

    var body: some View {
        AteSheetScaffold(
            title: ListsCopy.addToList,
            commit: AteSheetCommit(
                title: added > 0 ? ListsCopy.addToLists(added) : ListsCopy.done,
                action: { dismiss() }
            )
        ) {
            VStack(spacing: 0) {
                AteDishRow(
                    photo: .dish(target.line.dishID, name: target.name, cover: target.photoURL),
                    name: target.name,
                    subtitle: target.place,
                    score: target.score.map(AteScore.personal),
                    isFirst: true
                )
                .accessibilityIdentifier("addToList.dish")
                lists
                AteAddRow(title: ListsCopy.newList, identifier: "addToList.new") { isNaming = true }
            }
        }
        .task {
            await store.load()
            if heldAtStart == nil, store.phase == .ready {
                heldAtStart = Set(store.lists.filter(\.contains).map(\.listID))
            }
        }
        .sheet(isPresented: $isNaming, onDismiss: openMade) {
            ListNameSheet(title: ListsCopy.newList, initial: "") { name in
                let landed = await store.createList(named: name)
                if landed, onOpenList != nil, let made = store.created { opening = ListRoute(made) }
                return landed
            }
        }
        .listsFailureAlert(failure: isNaming ? nil : store.failure) { store.clearFailure() }
    }

    private func openMade() {
        guard let route = opening else { return }
        opening = nil
        dismiss()
        onOpenList?(route)
    }

    @ViewBuilder
    private var lists: some View {
        switch store.phase {
        case .loading:
            AteSheetSkeletonRows(count: ListsMetrics.skeletonRows, hasSubtitle: false)
                .ateBreathing()
        case .failed:
            AteEmptyState(line: ListsCopy.unreachable, art: .torn,
                pill: (ListsCopy.tryAgain, { Task { await store.load() } }))
                .frame(minHeight: ListsMetrics.emptyMinimum)
        case .ready:
            ForEach(store.lists) { membership in
                AteListTickRow(name: membership.name, isOn: membership.contains, identifier: "addToList.list") {
                    AteHaptics.tick()
                    Task { await store.toggle(membership) }
                }
            }
        }
    }
}
