import Foundation

/// Where a share went. The share screen's own row (`Share to`), plus the two ways out of it.
public enum ShareDestination: String, Sendable, CaseIterable, Codable {
    /// The sticker landed in Instagram's story editor.
    case instagramStories = "instagram_stories"
    /// The link went to the clipboard.
    case link
    /// Messages, with the link and the picture.
    case messages
    /// The picture was written to Photos — for a Reel, a TikTok, a carousel.
    case saved
    /// The sticker went to the clipboard (no longer offered; kept so old events still decode).
    case clipboard
    /// "More": the system sheet, whichever app it picked.
    case system
}

/// Which page left: the receipt on the entry's photo, or the receipt alone on the coral ground.
public enum ShareSticker: String, Sendable, CaseIterable, Codable {
    case photo, slip
}

/// **The share loop, counted** (PRODUCT.md principle 6: the receipt is the marketing). Built here so
/// the names and parameters are pinned by tests; sent by the app's ``AnalyticsRecorder``.
public enum ShareEvents {
    /// A receipt left the app — the north-star event, under its existing name, now carrying where it
    /// went and which sticker it was. `source` is the screen the share started on.
    public static func receiptShared(
        entryID: UUID, source: ReceiptShareSource, destination: ShareDestination, sticker: ShareSticker
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "receipt_shared", parameters: [
            "entry_id": entryID.uuidString.lowercased(),
            "source": source.rawValue,
            "destination": destination.rawValue,
            "sticker": sticker.rawValue
        ])
    }

    /// A list left the app, as a link (or its cover, to Stories). `count` is how many dishes it holds.
    public static func listShared(listID: UUID, destination: ShareDestination, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "list_shared", parameters: [
            "list_id": listID.uuidString.lowercased(),
            "destination": destination.rawValue,
            "count": String(max(0, count))
        ])
    }
}
