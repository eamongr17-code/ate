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

extension View {
    /// **Opens a link into the app** — `ate://entry/<id>` pushes that entry's page on the current tab.
    /// Anything else is ignored (and counted, so a malformed link in the wild shows up). Hung on the
    /// shell once.
    func ateOpensEntryLinks(_ open: @escaping (UUID) -> Void) -> some View {
        onOpenURL { url in
            let link = AteLinks.parse(url)
            AteTelemetry.record(LinkEvents.linkOpened(link))
            guard case .entry(let id)? = link else { return }
            open(id)
        }
    }
}
