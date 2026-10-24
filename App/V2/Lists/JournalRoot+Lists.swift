import AteKit
import SwiftUI
import TipKit

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

/// **Journal  Lists** (`journal-header.html` B, 24 Oct): the header's two titles are the switch, the
/// shelf under them, and on the Lists shelf the glass group's filter swapped for New list (Lucide
/// list-plus).
extension JournalRoot {
    var shelfTitles: some View {
        AteTitleTabs(
            options: [AteSegment(JournalShelf.journal, JournalShelf.journal.title),
                      AteSegment(.lists, JournalShelf.lists.title)],
            selection: $shelf,
            identifier: "journal.shelf"
        )
        // The last first-run tip: Lists, once there is enough on the Journal to make one from. It
        // points at the Lists title, anchored on a clear twin of the row's trailing half.
        .overlay {
            HStack(spacing: 0) {
                Color.clear
                Color.clear.popoverTip(listsTip, arrowEdge: .top)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: shelf) { _, now in
            guard now == .lists else { return }
            ListsTip().invalidate(reason: .actionPerformed)
            app.services.analytics(ListEvents.shelfOpened())
        }
    }

    /// The Lists tip, from the fifth entry, while the Journal shelf is the one showing.
    private var listsTip: ListsTip? {
        shelf == .journal && journal.entries.count >= AteTips.listsAfterEntries ? ListsTip() : nil
    }

    @ViewBuilder
    var shelfContent: some View {
        switch shelf {
        case .journal:
            list
        case .lists:
            ListsShelf(
                app: app, router: router, barHidden: $barHidden, isNaming: $isNamingList
            )
        }
    }

    var newListItem: some View {
        AteGlassItem(icon: .listPlus, label: ListsCopy.newList) {
            guard app.gate.permitsWrite(.journal) else { return }
            app.services.analytics(ListEvents.ctaTapped(from: .glass))
            isNamingList = true
        }
        .accessibilityIdentifier("lists.new")
    }
}
