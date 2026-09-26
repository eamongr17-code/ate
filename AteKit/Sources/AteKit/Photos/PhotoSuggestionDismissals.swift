import Foundation

/// **The sittings somebody said no to.** An X on a `Suggestions` row dismisses its photos for good:
/// tap to enter, X to dismiss, gone after — and gone for the next launch, and for the header's badge.
///
/// Remembered per asset, not per row: a row is only a guess about which photos belong together, and
/// the guess moves as new photos land. Keyed by the person, so what one account dismissed on a
/// shared phone never hides the next account's photos. Local on purpose: which photos in *your*
/// camera roll you did not want to write up is not something the server needs to know.
///
/// Each id is kept with when its photo was taken, and anything older than the window
/// ``PhotoSuggestions`` looks back over is dropped on the way in — it could never be offered again,
/// so remembering it would only grow the list forever.
@MainActor
public final class PhotoSuggestionDismissals {
    private let store: any AteKeyValueStore
    private let key: String
    private let now: () -> Date
    private var dismissed: [String: Date]

    public init(store: any AteKeyValueStore, owner: UUID?, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.key = "ate.dismissedSuggestions." + (owner?.uuidString.lowercased() ?? "signed-out")
        self.now = now
        self.dismissed = Self.decode(store.value(forKey: key))
    }

    /// Whether this photo was dismissed.
    public func contains(_ id: String) -> Bool { dismissed[id] != nil }

    /// The photos still on offer.
    public func visible(_ items: [PhotoSuggestionItem]) -> [PhotoSuggestionItem] {
        items.filter { dismissed[$0.id] == nil }
    }

    /// The sittings still on offer — `items`, less every dismissed photo, grouped.
    public func clusters(_ items: [PhotoSuggestionItem]) -> [PhotoSuggestionCluster] {
        PhotoSuggestions.cluster(visible(items), now: now())
    }

    /// How many photos are waiting — the journal header's badge.
    public func count(_ items: [PhotoSuggestionItem]) -> Int {
        clusters(items).reduce(0) { $0 + $1.items.count }
    }

    /// The X. Every photo in the row goes, and stays gone.
    public func dismiss(_ cluster: PhotoSuggestionCluster) {
        for item in cluster.items { dismissed[item.id] = item.createdAt }
        let horizon = now().addingTimeInterval(-PhotoSuggestions.window)
        dismissed = dismissed.filter { $0.value >= horizon }
        store.setValue(Self.encode(dismissed), forKey: key)
    }

    // MARK: - Storage

    private struct Row: Codable {
        let id: String
        let takenAt: Date
    }

    private static func decode(_ string: String?) -> [String: Date] {
        guard let data = string?.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [:] }
        return Dictionary(rows.map { ($0.id, $0.takenAt) }, uniquingKeysWith: { first, _ in first })
    }

    private static func encode(_ dismissed: [String: Date]) -> String? {
        let rows = dismissed.map { Row(id: $0.key, takenAt: $0.value) }.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
