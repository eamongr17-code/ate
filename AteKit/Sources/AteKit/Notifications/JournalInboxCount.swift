import Foundation

/// **The Journal's one coral count** — the bell in the Journal's glass group: unread "ate with" tags
/// (the server's `unread_notification_count()`) plus the photo sittings waiting on this phone (the
/// count the photos control showed, ``PhotoSuggestionDismissals/count(_:)``). No server change: the
/// phone adds the two.
public struct JournalInboxCount: Sendable, Hashable {
    public let ateWith: Int
    public let photos: Int

    public init(ateWith: Int, photos: Int) {
        self.ateWith = max(0, ateWith)
        self.photos = max(0, photos)
    }

    /// From the camera roll's recent items, less what was dismissed — the same source as before.
    @MainActor
    public init(ateWith: Int, recentPhotos: [PhotoSuggestionItem], dismissals: PhotoSuggestionDismissals) {
        self.init(ateWith: ateWith, photos: dismissals.count(recentPhotos))
    }

    public static let zero = JournalInboxCount(ateWith: 0, photos: 0)

    /// The badge's number. Zero draws no badge.
    public var total: Int { ateWith + photos }
    public var isEmpty: Bool { total == 0 }

    public func with(ateWith: Int) -> JournalInboxCount { JournalInboxCount(ateWith: ateWith, photos: photos) }
    public func with(photos: Int) -> JournalInboxCount { JournalInboxCount(ateWith: ateWith, photos: photos) }
}
