import AteKit
import SwiftUI

/// **Add people** (`list-cover-edit.html` 5, approved 18 Oct) — "Who were you with?"'s picker, for a
/// list: close, "People on this list", the search pill. People already on the list, or invited, come
/// ticked; untick to take someone off or withdraw their invite. Before typing, the people you've
/// tagged; typing searches every handle. The foot counts who is new ("Invite 2 people"), or says
/// Done when the change is only taking people off. Twenty at most.
struct ListPeopleSheet: View {
    let list: ListStore

    @State private var store: CompanionPickerStore
    @Environment(\.dismiss) private var dismiss

    init(list: ListStore, services: AteServices) {
        self.list = list
        let standing = list.people.map {
            CompanionPerson(userID: $0.id, handle: $0.username, avatarURL: $0.avatarURL)
        }
        _store = State(initialValue: CompanionPickerStore(
            service: services.companions, selected: standing, limit: ListRules.peopleCap
        ))
    }

    var body: some View {
        @Bindable var store = store
        AteSheetScaffold(
            title: ListsCopy.peopleOnThisList,
            searchPrompt: ListsCopy.searchHandles,
            searchText: $store.query,
            commit: AteSheetCommit(title: commitTitle, isEnabled: hasChanged, action: commit)
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                if store.selected.isEmpty == false {
                    AteFilterChipRow(
                        chips: store.selected.map {
                            AteFilterChipRow.Chip(id: $0.userID.uuidString, title: "@\($0.handle)")
                        },
                        onClear: { chip in
                            guard let person = store.selected.first(where: { $0.userID.uuidString == chip.id }) else {
                                return
                            }
                            AteHaptics.key()
                            store.remove(person)
                        }
                    )
                    // The chip row lays its own list gutter; in a sheet the body already has one.
                    .padding(.horizontal, -AteMetrics.listGutter)
                    .accessibilityIdentifier("people.chips")
                }
                rows
            }
        }
        .task { await store.loadRecents() }
        .listsFailureAlert(failure: list.failure) { list.clearFailure() }
    }

    @ViewBuilder
    private var rows: some View {
        if store.phase == .loading && store.rows.isEmpty {
            AteSheetSkeletonRows(count: ComposerWithSheetMetrics.skeletonRows)
        } else {
            let recentIDs = Set(store.recents.map(\.userID))
            let firstRecent = store.isSearching ? nil : store.rows.first { recentIDs.contains($0.userID) }?.userID
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, person in
                    if person.userID == firstRecent {
                        AteBandHeading(title: ListsCopy.peopleYouAteWith)
                            .padding(.top, index == 0 ? 0 : ListPeopleSheetMetrics.bandTop)
                            .padding(.bottom, ListPeopleSheetMetrics.bandBottom)
                            .accessibilityAddTraits(.isHeader)
                    }
                    AtePersonPickRow(
                        person: AteWithPerson(id: person.userID, handle: person.handle),
                        name: person.name,
                        isSelected: store.isSelected(person),
                        isFirst: index == 0 || person.userID == firstRecent
                    ) {
                        toggle(person)
                    }
                    .onAppear {
                        if index == store.rows.count - 1 { Task { await store.loadMore() } }
                    }
                }
            }
        }
    }

    // MARK: - The foot

    /// Who the commit would add — the people ticked who were not on the list when it opened.
    private var newcomers: Int {
        let standing = Set(store.initial.map(\.userID))
        return store.selected.filter { standing.contains($0.userID) == false }.count
    }

    private var hasChanged: Bool {
        Set(store.selected.map(\.userID)) != Set(store.initial.map(\.userID))
    }

    private var commitTitle: String {
        newcomers > 0 ? ListsCopy.invitePeople(newcomers) : ListsCopy.done
    }

    // MARK: - Doing

    /// A tap ticks or unticks; a twenty-first is refused under the finger, never in words.
    private func toggle(_ person: CompanionPerson) {
        if store.toggle(person) {
            AteHaptics.key()
        } else {
            AteHaptics.refused()
        }
    }

    private func commit() {
        let wanted = store.selected.map {
            ListPerson(id: $0.userID, username: $0.handle, avatarURL: $0.avatarURL, status: .invited)
        }
        AteHaptics.key()
        Task {
            // A refusal keeps the sheet up, said once in the alert.
            if await list.setPeople(wanted) { dismiss() }
        }
    }
}

enum ListPeopleSheetMetrics {
    /// `.bandp{padding:6px 0 12px}`, with the rows' own 18 above when it follows ticked people.
    static let bandTop: CGFloat = 18
    static let bandBottom: CGFloat = 12
}
