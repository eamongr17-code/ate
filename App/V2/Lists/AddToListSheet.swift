import AteKit
import SwiftUI

/// What the Add to a list sheet is about: one or more of your own dish lines from one visit, and how
/// to draw them.
struct AddToListTarget: Identifiable {
    struct Dish: Identifiable, Hashable {
        let line: DishLine
        let name: String
        var score: Rating?
        var photoURL: String?

        var id: DishLine { line }
    }

    /// At least one, in the order they go on a list.
    let dishes: [Dish]
    var place: String?

    var id: [DishLine] { dishes.map(\.line) }

    init(dishes: [Dish], place: String?) {
        self.dishes = dishes
        self.place = place
    }

    init(line: DishLine, name: String, place: String?, score: Rating?, photoURL: String?) {
        self.init(dishes: [Dish(line: line, name: name, score: score, photoURL: photoURL)], place: place)
    }
}

/// **Add to a list** (`lists-notifications.html` D2) — close, the title, the dish as context, then
/// your lists by name with a tick where one already holds it (no counts — Eamon, on the page). A tap
/// adds or takes it off at once; "New list" is the last row: the dish goes on the list it makes,
/// then this sheet closes and that list's page opens (`onOpenList`).
/// The pill counts the lists it went onto ("Add to 2 lists"), or says Done. Several dishes (an entry's
/// "Add to a list", ``AddEntryToListSheet``) are one tick: a list is ticked when it holds all of them.
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
            lines: target.dishes.map(\.line), service: app.services.lists, shelf: app.lists,
            analytics: app.services.analytics
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
                // Every dish going on, as context: an entry's picked dishes go on together.
                ForEach(Array(target.dishes.enumerated()), id: \.element.id) { index, dish in
                    AteDishRow(
                        photo: .dish(dish.line.dishID, name: dish.name, cover: dish.photoURL),
                        name: dish.name,
                        subtitle: target.place,
                        score: dish.score.map(AteScore.personal),
                        isFirst: index == 0
                    )
                    .accessibilityIdentifier("addToList.dish")
                }
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
                .ateSkeletonSweep()
        case .failed:
            AteEmptyState(line: ListsCopy.unreachable, art: .unplugged,
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

/// **An entry's "Add to a list"** (`journal-dish-to-list.html` B, Eamon picked 28 Oct) — the pill under
/// your own receipt. One dish goes straight to ``AddToListSheet``; with several, this sheet asks which
/// ones first ("Which dishes?", none ticked), and Next turns it into the lists sheet for all of them.
struct AddEntryToListSheet: View {
    let entry: AddToListTarget
    let app: AppModel
    var onOpenList: ((ListRoute) -> Void)?

    @State private var picked: [AddToListTarget.Dish] = []
    @State private var chosen: AddToListTarget?

    var body: some View {
        if let chosen {
            AddToListSheet(target: chosen, app: app, onOpenList: onOpenList)
        } else if entry.dishes.count == 1 {
            AddToListSheet(target: entry, app: app, onOpenList: onOpenList)
        } else {
            AteSheetScaffold(
                title: ListsCopy.whichDishes,
                commit: AteSheetCommit(title: ListsCopy.next, isEnabled: picked.isEmpty == false, action: next)
            ) {
                let letters = DishLetter.neighbourly(entry.dishes.map { ($0.line.dishID, $0.name) })
                VStack(spacing: 0) {
                    ForEach(Array(entry.dishes.enumerated()), id: \.element.id) { index, dish in
                        AtePickRow(
                            photo: .dish(letters[index], cover: dish.photoURL),
                            name: dish.name,
                            place: entry.place,
                            score: dish.score.map(AteScore.personal),
                            isSelected: picked.contains(dish),
                            isFirst: index == 0,
                            identifier: "addToList.pick"
                        ) {
                            AteHaptics.tick()
                            toggle(dish)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ dish: AddToListTarget.Dish) {
        if let at = picked.firstIndex(of: dish) { picked.remove(at: at) } else { picked.append(dish) }
    }

    /// The picked dishes, in the entry's order.
    private func next() {
        let order = entry.dishes.filter { picked.contains($0) }
        guard order.isEmpty == false else { return }
        AteHaptics.key()
        chosen = AddToListTarget(dishes: order, place: entry.place)
    }
}
