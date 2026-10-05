import AteKit
import SwiftUI

/// The Journal root's two shelves: your record, and your lists.
enum JournalShelf: Hashable {
    case journal
    case lists

    var title: String {
        switch self {
        case .journal: "Journal"
        case .lists: "Lists"
        }
    }
}

/// **Journal | Lists** (`lists-notifications.html` §3): the pinned switch, the shelf under it, and
/// on the Lists shelf the glass group's filter swapped for New list (Lucide list-plus).
extension JournalRoot {
    var shelfSwitch: some View {
        AteSegmentedControl(
            options: [AteSegment(JournalShelf.journal, JournalShelf.journal.title),
                      AteSegment(.lists, JournalShelf.lists.title)],
            selection: $shelf,
            identifier: "journal.shelf"
        )
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.vertical, AteMetrics.tight)
    }

    @ViewBuilder
    var shelfContent: some View {
        switch shelf {
        case .journal:
            list
        case .lists:
            ListsShelf(app: app, router: router, isCollapsed: $isCollapsed, isNaming: $isNamingList)
        }
    }

    var newListItem: some View {
        AteGlassItem(icon: .listPlus, label: ListsCopy.newList) {
            guard app.gate.permitsWrite(.journal) else { return }
            isNamingList = true
        }
        .accessibilityIdentifier("lists.new")
    }
}
