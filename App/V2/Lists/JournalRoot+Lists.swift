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
        // The last first-run tip: Lists, once there is enough on the Journal to make one from. It
        // points at the Lists half, not the middle of the switch: anchored on a clear twin of it.
        .overlay {
            HStack(spacing: 0) {
                Color.clear
                Color.clear.popoverTip(listsTip, arrowEdge: .top)
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.vertical, AteMetrics.tight)
        .onChange(of: shelf) { _, now in
            if now == .lists { ListsTip().invalidate(reason: .actionPerformed) }
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
            ListsShelf(app: app, router: router, isCollapsed: $isCollapsed, isNaming: $isNamingList)
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
