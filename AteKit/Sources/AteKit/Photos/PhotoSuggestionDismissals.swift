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
///
/// **Written up** is the other way a sitting goes: a photo posted with an entry (from a suggestion
/// or the picker — both carry the library's own id) takes its sitting with it, as it was when the
/// entry was posted. A photo taken after that is still offered. Kept with when it was posted, which
/// is never before the photo was taken, so the same window ages it out.
@MainActor
public final class PhotoSuggestionDismissals {
    private let store: any AteKeyValueStore
    private let key: String
    private let writtenUpKey: String
    private let now: () -> Date
    private var dismissed: [String: Date]
    private var writtenUp: [String: Date]

    public init(store: any AteKeyValueStore, owner: UUID?, now: @escaping () -> Date = Date.init) {
        let person = owner?.uuidString.lowercased() ?? "signed-out"
        self.store = store
        self.key = "ate.dismissedSuggestions." + person
        self.writtenUpKey = "ate.writtenUpSuggestions." + person
        self.now = now
        self.dismissed = Self.decode(store.value(forKey: key))
        self.writtenUp = Self.decode(store.value(forKey: writtenUpKey))
    }

    /// Whether this photo was dismissed.
    public func contains(_ id: String) -> Bool { dismissed[id] != nil }

    /// Whether this photo went out with an entry.
    public func isWrittenUp(_ id: String) -> Bool { writtenUp[id] != nil }

    /// The photos still on offer: none dismissed, none posted, and nothing from a posted photo's
    /// sitting that was already taken when it was posted.
    public func visible(_ items: [PhotoSuggestionItem]) -> [PhotoSuggestionItem] {
        let kept = items.filter { dismissed[$0.id] == nil }
        guard writtenUp.isEmpty == false else { return kept }
        return PhotoSuggestions.sittings(kept, now: now()).flatMap { sitting -> [PhotoSuggestionItem] in
            guard let postedAt = sitting.compactMap({ writtenUp[$0.id] }).max() else { return sitting }
            return sitting.filter { writtenUp[$0.id] == nil && $0.createdAt > postedAt }
        }
    }

    /// The sittings still on offer — `items`, less every dismissed photo, grouped.
    public func clusters(_ items: [PhotoSuggestionItem]) -> [PhotoSuggestionCluster] {
        PhotoSuggestions.cluster(visible(items), now: now())
    }

    /// How many photos are waiting — the journal header's badge.
    public func count(_ items: [PhotoSuggestionItem]) -> Int {
        clusters(items).reduce(0) { $0 + $1.items.count }
    }

    /// The X. Every photo in the row goes, and stays gone — with the rest of its sitting, which would
    /// otherwise come straight back as a row of its own.
    public func dismiss(_ cluster: PhotoSuggestionCluster) {
        for item in cluster.items + cluster.others { dismissed[item.id] = item.createdAt }
        let horizon = now().addingTimeInterval(-PhotoSuggestions.window)
        dismissed = dismissed.filter { $0.value >= horizon }
        store.setValue(Self.encode(dismissed), forKey: key)
    }

    /// An entry went out holding these photos (library ids; anything else is simply never matched).
    public func writeUp(_ ids: [String]) {
        guard ids.isEmpty == false else { return }
        let postedAt = now()
        for id in ids { writtenUp[id] = postedAt }
        let horizon = postedAt.addingTimeInterval(-PhotoSuggestions.window)
        writtenUp = writtenUp.filter { $0.value >= horizon }
        store.setValue(Self.encode(writtenUp), forKey: writtenUpKey)
    }

    /// Replay first run: every dismissed sitting on offer again, as a new account sees the roll.
    /// Photos already posted stay off: they are in the Journal.
    public func reset() {
        dismissed = [:]
        store.setValue(nil, forKey: key)
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
