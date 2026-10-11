import AteKit
import LinkPresentation
import UIKit

/// What a list shares: enough to name it in a link's preview.
struct ListShare: Equatable {
    let id: UUID
    let name: String
    let count: Int
    /// The cover's photos, in list order (four at most).
    var covers: [String] = []
    let handle: String

    var countLine: String { count == 1 ? "1 dish" : "\(count) dishes" }
}

/// **Share: a list** (11 Oct, Eamon: no full-screen takeover) — a link, the way a playlist is,
/// never a picture of its lines. Share goes straight to the system share sheet, whose header carries
/// the preview: the cover, and the name with the count. The link opens the list in Ate
/// (``AteLinks/list(_:)``).
enum ListLinkShare {
    /// The sheet's items: the link, dressed with the list's name, count and cover. The cover is the
    /// one the page already shows, so it is normally on hand without a wait.
    @MainActor
    static func items(for share: ListShare) async -> [Any] {
        [ListLinkItem(url: AteLinks.list(share.id), title: title(for: share), cover: await cover(for: share))]
    }

    static func title(for share: ListShare) -> String { "\(share.name) · \(share.countLine)" }

    @MainActor
    private static func cover(for share: ListShare) async -> UIImage? {
        guard let url = share.covers.first.flatMap(URL.init(string:)) else { return nil }
        if let held = AteImagePipeline.shared.bestCached(url, size: .large) { return held.image }
        return await AteImagePipeline.shared.image(url, size: .thumbnail)
    }
}

/// The list's link as an activity item: the URL travels, the sheet's header shows the cover and title.
final class ListLinkItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let cover: UIImage?

    init(url: URL, title: String, cover: UIImage?) {
        self.url = url
        self.title = title
        self.cover = cover
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? { url }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String { title }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let cover {
            metadata.imageProvider = NSItemProvider(object: cover)
            metadata.iconProvider = NSItemProvider(object: cover)
        }
        return metadata
    }
}
