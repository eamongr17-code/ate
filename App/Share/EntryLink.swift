import AteKit
import LinkPresentation
import SwiftUI
import UIKit

/// **Sharing somebody else's entry** (round 5, Eamon): a link to it, never their receipt — whoever
/// gets it opens the review inside Ate. Your own entry still shares its printed receipt (`Share`).
///
/// The link is ``AteLinks/entry(_:)``: `ate://entry/<id>` for now, app-only, no web fallback.
enum EntryLinkShare {
    /// What the system share sheet is handed: the link, dressed so the sheet's header (and a message
    /// preview) names the dishes rather than showing a bare URL.
    static func items(for card: EntryCard, handle: String?) -> [Any] {
        AteTelemetry.record(LinkEvents.entryLinkShared(entryID: card.id))
        return [EntryLinkItem(url: AteLinks.entry(card.id), title: title(for: card, handle: handle))]
    }

    /// The dishes, in the entry's order — the dish is the item (dish-first). A visit with none
    /// sorted yet is named by its author.
    static func title(for card: EntryCard, handle: String?) -> String {
        let dishes = card.items.sorted { $0.position < $1.position }.map(\.dishName).filter { $0.isEmpty == false }
        if dishes.isEmpty == false { return dishes.joined(separator: ", ") }
        return handle.map { "@\($0)" } ?? "Ate"
    }
}

/// The link as an activity item, with its title for the share sheet's header.
final class EntryLinkItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? { url }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        return metadata
    }
}

// MARK: - Opening a link

extension View {
    /// **Opens links into the app** — `ate://entry/<id>` — wherever the shell is. A link is held
    /// (``EntryLinkInbox``) until the shell can open it: past `Welcome` (into browsing), after the
    /// first-run handle step, once the composer or the sign-in ask has gone. A cold start is the same
    /// path — SwiftUI hands the launch URL to this handler once the shell is up. Anything that is not
    /// one of ours is counted as unrecognised and opens nothing.
    func ateEntryLinks(
        _ situation: EntryLinkInbox.Situation,
        open: @escaping (_ entryID: UUID, _ browseFirst: Bool) -> Void
    ) -> some View {
        modifier(EntryLinkHost(situation: situation, open: open))
    }
}

private struct EntryLinkHost: ViewModifier {
    let situation: EntryLinkInbox.Situation
    let open: (UUID, Bool) -> Void

    @State private var inbox = EntryLinkInbox()

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard case .entry(let entryID)? = AteLinks.parse(url) else {
                    AteTelemetry.record(LinkEvents.linkOpened(nil))
                    return
                }
                inbox.receive(entryID)
                deliver()
            }
            .onChange(of: situation) { _, _ in
                // A turn later, so whatever changed the situation (the composer's Done landing on
                // the Journal) has finished moving the stack before the link pushes onto it.
                Task { @MainActor in
                    await Task.yield()
                    deliver()
                }
            }
    }

    private func deliver() {
        switch inbox.next(situation) {
        case .wait: break
        case .open(let entryID): open(entryID, false)
        case .browseAndOpen(let entryID): open(entryID, true)
        }
    }
}

extension AteShell {
    /// Where the shell is, as far as a waiting link cares.
    var linkSituation: EntryLinkInbox.Situation {
        EntryLinkInbox.Situation(
            hasSession: hasSession,
            isBrowsing: gate.isBrowsing,
            owesHandle: hasSession && owesHandle,
            isCovered: composing != nil || gate.isAsking
        )
    }

    /// A link's entry, pushed on the current tab — on the Feed for somebody reading signed out,
    /// since Journal and You are a signed-in person's own. `link_opened` is counted here, once the
    /// page is actually on its way.
    func openLinkedEntry(_ entryID: UUID, browseFirst: Bool) {
        if browseFirst {
            gate.browse()
            tab = .feed
        }
        if gate.isBrowsing, tab == .journal || tab == .you {
            tab = .feed
            path.removeAll()
        }
        if path.last?.entryID != entryID {
            open(.entry(EntryRoute(entryID: entryID)), from: .link)
        }
        AteTelemetry.record(LinkEvents.linkOpened(.entry(entryID)))
    }
}
