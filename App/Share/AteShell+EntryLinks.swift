import AteKit
import SwiftUI

extension AteShell {
    /// Where the shell is, as far as a waiting link cares. The page's own covers (sheets, the photo
    /// preview) and whether the tabs are up are folded in by the link host.
    var linkSituation: EntryLinkInbox.Situation {
        EntryLinkInbox.Situation(
            hasSession: hasSession,
            isBrowsing: gate.isBrowsing,
            owesHandle: hasSession && owesHandle,
            isCovered: composing != nil || gate.isAsking,
            isShellUp: false
        )
    }

    /// A link's entry, pushed on the current tab — on the Feed for somebody reading signed out,
    /// since Journal and You are a signed-in person's own. `browseFirst` only starts browsing; the
    /// link comes back here once the shell is up. `link_opened` is counted only for a page that was
    /// actually pushed.
    func openLinkedEntry(_ entryID: UUID, browseFirst: Bool) {
        if browseFirst {
            gate.browse()
            tab = .feed
            return
        }
        if gate.isBrowsing, tab == .journal || tab == .you {
            tab = .feed
            path.removeAll()
        }
        guard path.last?.entryID != entryID else { return }
        let depth = path.count
        open(.entry(EntryRoute(entryID: entryID)), from: .link)
        if path.count > depth {
            AteTelemetry.record(LinkEvents.linkOpened(.entry(entryID)))
        }
    }
}
