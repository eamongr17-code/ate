import Foundation
import Observation

/// What `delete_entry(p_entry_id)` answers (0037): the bucket-relative `review-photos` paths the
/// entry's photos — originals and their `_t.jpg` thumbnails — were uploaded to.
///
/// The row, its dish lines and its photo rows are gone server-side by the time this arrives; the
/// files are the client's to remove, because storage is not reachable from a SQL transaction. A
/// thumbnail the server did not list is derived anyway (``PhotoAddress/withThumbnails(_:)``) —
/// removing a path that is not there costs nothing.
public struct EntryDeletion: Sendable, Hashable, Decodable {
    public let photoPaths: [String]

    public init(photoPaths: [String]) {
        self.photoPaths = photoPaths
    }

    enum CodingKeys: String, CodingKey {
        case photoPaths = "photo_paths"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photoPaths = try container.decodeIfPresent([String].self, forKey: .photoPaths) ?? []
    }

    /// `P0002` — the entry is not there. Deleting something already deleted is success, not an error.
    public static func isAlreadyGone(code: String?) -> Bool {
        code == "P0002"
    }

    /// The bucket the entry photos live in.
    public static let bucket = "review-photos"

    /// Every file to remove from ``bucket``: each photo and its `_t.jpg`, as paths inside the
    /// bucket. A full public URL is cut back to its path, so a server that answers with URLs rather
    /// than paths still cleans up after itself instead of asking storage to remove nothing.
    public var storageFiles: [String] {
        PhotoAddress.withThumbnails(photoPaths.compactMap(Self.bucketPath))
    }

    static func bucketPath(_ value: String) -> String? {
        let marker = "/\(bucket)/"
        if let range = value.range(of: marker) {
            let path = String(value[range.upperBound...])
            return path.isEmpty ? nil : path.removingPercentEncoding ?? path
        }
        let trimmed = value.hasPrefix("/") ? String(value.dropFirst()) : value
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `delete_entry` returns one jsonb object; tolerate the single-row array a `returns table`
    /// function would give, so a signature change on the server is not a failed delete here.
    public static func decode(_ data: Data) throws -> EntryDeletion {
        let decoder = JSONDecoder()
        if let object = try? decoder.decode(EntryDeletion.self, from: data) { return object }
        if let rows = try? decoder.decode([EntryDeletion].self, from: data) {
            return EntryDeletion(photoPaths: rows.flatMap(\.photoPaths))
        }
        // `void` / `null`: the entry went, and there was nothing in storage to follow it.
        let text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty || text == "null" {
            return EntryDeletion(photoPaths: [])
        }
        return try decoder.decode(EntryDeletion.self, from: data)
    }
}

/// Something that shows entries and must stop showing one the moment it is deleted.
@MainActor
public protocol EntryDeletionObserving: AnyObject {
    func entryDeleted(_ entryID: UUID)
}

/// **One delete, every list at once.** The journal, the feed and any profile that is open all drop
/// the entry in the same turn — nothing is hand-wired, so nothing can be forgotten (the pattern
/// ``SavedDishBroadcast`` proved). Observers are held weakly and pruned as they go: a popped profile
/// unregisters by being deallocated.
@MainActor
public final class EntryDeletions {
    private var observers: [WeakObserver] = []

    public init() {}

    public func add(_ observer: any EntryDeletionObserving) {
        prune()
        guard observers.contains(where: { $0.value === observer }) == false else { return }
        observers.append(WeakObserver(value: observer))
    }

    public func send(_ entryID: UUID) {
        prune()
        for observer in observers {
            observer.value?.entryDeleted(entryID)
        }
    }

    public var observerCount: Int {
        prune()
        return observers.count
    }

    private func prune() {
        observers.removeAll { $0.value == nil }
    }

    private struct WeakObserver {
        weak var value: (any EntryDeletionObserving)?
    }
}

/// **Deleting an entry**, as one flow: the server first, the lists after — never the other way
/// round, because an entry that vanished from the journal and then came back on the next refresh
/// would be worse than one that took a beat to go.
@MainActor
public struct EntryDeleter {
    private let entries: any EntryService
    private let deletions: EntryDeletions
    private let analytics: AnalyticsRecorder
    /// The queue of unfinished writes. The entry leaves it before the server is asked to delete it.
    private let outbox: EntryOutbox?

    public init(
        entries: any EntryService,
        deletions: EntryDeletions,
        analytics: @escaping AnalyticsRecorder,
        outbox: EntryOutbox? = nil
    ) {
        self.entries = entries
        self.deletions = deletions
        self.analytics = analytics
        self.outbox = outbox
    }

    /// Returns whether it went. On success every listening list has already dropped the entry and
    /// `entry_deleted` has been sent; on a failure nothing has moved.
    @discardableResult
    public func delete(_ card: EntryCard) async -> Bool {
        // The outbox first: a queued photo or sort for this entry must never run again, and a push
        // already in the air is waited out, so nothing lands after the delete and brings it back.
        let queued = await outbox?.forget(entryID: card.id)
        do {
            let result = try await entries.delete(entryID: card.id)
            deletions.send(card.id)
            analytics(EntryEvents.deleted(
                photoCount: max(card.photos.count, result.photoPaths.count),
                dishCount: card.items.count
            ))
            return true
        } catch {
            await outbox?.restore(queued, entryID: card.id)
            return false
        }
    }
}
