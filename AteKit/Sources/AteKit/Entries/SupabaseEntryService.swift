import Foundation
import Supabase

/// The live entry path, written straight against `docs/backend/integration-design.md`.
///
/// Every read decodes with ``PostgRESTDate/decoder`` from the response's own bytes rather than
/// through whatever decoder the Supabase client was configured with: `entry_cards` is a view of
/// microsecond timestamps, and a cursor built from a truncated one silently skips rows.
public struct SupabaseEntryService: EntryService {
    private let api: AteAPIClient
    private let profiles: any ViewerProfileReading

    public init(api: AteAPIClient, profiles: (any ViewerProfileReading)? = nil) {
        self.api = api
        self.profiles = profiles ?? ViewerProfileClient(api: api)
    }

    public func viewer() async throws -> ViewerProfile {
        try await profiles.viewer()
    }

    /// The cached session's user first: `requireCurrentUserID()` refreshes an expired token, which
    /// is a network call, and an entry written on a tram still has an author.
    public func authorID() async throws -> UUID {
        if let id = api.currentUserID { return id }
        return try await api.requireCurrentUserID()
    }

    // MARK: - Write

    @discardableResult
    public func create(_ entry: NewEntry) async throws -> EntryCard {
        try await insert(entry)
        return try await self.entry(id: entry.id)
    }

    public func insert(_ entry: NewEntry) async throws {
        do {
            _ = try await api.supabase
                .from("entries")
                .insert(entry, returning: .minimal)
                .execute()
        } catch {
            // `23505` on an entry insert means the entry already landed: the id is the client's, so
            // the row that is there is ours. Treat it as the success it is (contract, Errors).
            guard isDuplicateKey(error) else { throw EntryWriteFailure.of(error) }
        }
    }

    public func warmUp() async {
        _ = try? await api.supabase.functions.invoke(
            "sort-entry",
            options: FunctionInvokeOptions(method: .post, body: ["health": true])
        ) { _, _ in () }
    }

    public func attach(photo: EntryPhotoUpload) async throws {
        let userID = try await api.requireCurrentUserID()
        let path = "\(userID.uuidString.lowercased())/\(photo.objectName())"
        // Overwrites, so a retried upload is the same object (the path is deterministic). The small
        // copy (`_t.jpg`, what lists draw) goes up beside it at the same time. Supabase Storage or
        // R2, whichever the server names (``AteAPIClient/uploadPhoto(bucket:path:data:contentType:)``).
        let thumbnail = PhotoThumbnail.jpeg(from: photo.data)
        async let full = api.uploadPhoto(
            bucket: Self.photoBucket, path: path, data: photo.data, contentType: "image/jpeg"
        )
        if let thumbnail {
            _ = try await api.uploadPhoto(
                bucket: Self.photoBucket, path: PhotoThumbnail.path(for: path), data: thumbnail,
                contentType: "image/jpeg"
            )
        }
        let url = try await full
        try await attachExisting(entryID: photo.entryID, position: photo.position, url: url)
    }

    public func attachExisting(entryID: UUID, position: Int, url: String) async throws {
        _ = try await api.supabase
            .from("entry_photos")
            .upsert(
                EntryPhotoRow(entryID: entryID, position: position, photoURL: url),
                onConflict: "entry_id,position",
                returning: .minimal
            )
            .execute()
    }

    public func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws {
        _ = try await api.supabase
            .from("entry_photos")
            .delete(returning: .minimal)
            .eq("entry_id", value: entryID.uuidString.lowercased())
            .gte("position", value: position)
            .execute()
        // The rows are what the entry shows, and they are gone. The objects are the author's own
        // folder being tidied: only paths inside this bucket are named, and a miss changes nothing.
        let paths = removedURLs.compactMap(Self.storagePath(fromPublicURL:))
        guard paths.isEmpty == false else { return }
        try await api.removePhotos(bucket: Self.photoBucket, paths: PhotoAddress.withThumbnails(paths))
    }

    public func previewSort(_ input: EarlySortInput) async throws {
        let _: PreviewResponse = try await api.supabase.functions.invoke(
            "sort-entry",
            options: FunctionInvokeOptions(method: .post, body: PreviewSortRequest(input))
        )
    }

    static let photoBucket = "review-photos"

    @discardableResult
    public func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens, scoreTokens: nil)
    }

    @discardableResult
    public func sort(
        entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?
    ) async throws -> SortOutcome {
        try await sort(
            entryID: entryID, force: force, tagTokens: tagTokens, scoreTokens: scoreTokens, dietOffTokens: []
        )
    }

    @discardableResult
    public func sort(
        entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?, dietOffTokens: [DietOffToken]
    ) async throws -> SortOutcome {
        let response: SortResponse = try await api.supabase.functions.invoke(
            "sort-entry",
            options: FunctionInvokeOptions(
                method: .post,
                body: SortEntryRequest(
                    entryID: entryID, force: force, tagTokens: tagTokens, scoreTokens: scoreTokens,
                    dietOffTokens: dietOffTokens
                )
            )
        ) { data, _ in try Self.decodeSortResponse(data) }
        return SortOutcome(
            entryID: entryID,
            status: EntrySortStatus(rawValue: response.sortStatus ?? "sorted") ?? .sorted,
            mode: response.mode ?? "stub",
            itemCount: response.items?.count ?? 0,
            restaurantID: response.restaurantID.flatMap(UUID.init(uuidString:)),
            didAttachPlace: response.restaurantID != nil,
            card: response.entryCard?.card
        )
    }

    // MARK: - Read

    /// One entry by id — `get_entry_card` (0048), which answers signed in or signed out, so a shared
    /// link (`ate://entry/<id>`) opens for somebody browsing without a session. `[]` = not visible or
    /// gone, which the page draws as gone.
    public func entry(id: UUID) async throws -> EntryCard {
        let data = try await api.supabase
            .rpc("get_entry_card", params: ["p_entry_id": AnyJSON.string(id.uuidString.lowercased())])
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        guard let row = rows.first else { throw AteAPIError.notFound(table: EntryCard.table, id: id) }
        return row
    }

    public func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        let authorID = try await api.requireCurrentUserID()
        var parameters: [String: AnyJSON] = [
            "p_author_id": .string(authorID.uuidString.lowercased()),
            "p_page_size": .integer(pageSize)
        ]
        // First page → nulls. Next page → the LAST row's `created_at` AND `id` (contract, Reads).
        parameters["p_cursor_created_at"] = cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) }
            ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null

        let data = try await api.supabase
            .rpc("get_entries_by_author", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        return Page(items: rows, requestedLimit: pageSize)
    }

    // MARK: - The 6s left

    public func sixAllowance(editing entryID: UUID?) async throws -> SixAllowance? {
        let parameters: [String: AnyJSON] = [
            "p_entry_id": entryID.map { AnyJSON.string($0.uuidString.lowercased()) } ?? .null
        ]
        let data = try await api.supabase.rpc("six_allowance", params: parameters).execute().data
        return try PostgRESTDate.decoder.decode([SixAllowance].self, from: data).first
    }

    // MARK: - Corrections

    public func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard {
        let parameters: [String: AnyJSON] = [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_restaurant_id": .string(restaurantID.uuidString.lowercased())
        ]
        _ = try await api.supabase.rpc("correct_entry_place", params: parameters).execute()
        return try await entry(id: entryID)
    }

    public func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {
        let parameters: [String: AnyJSON] = [
            "p_review_id": .string(reviewID.uuidString.lowercased()),
            "p_dish_id": dishID.map { AnyJSON.string($0.uuidString.lowercased()) } ?? .null,
            "p_dish_name": dishName.map { AnyJSON.string($0) } ?? .null
        ]
        _ = try await api.supabase.rpc("correct_entry_dish", params: parameters).execute()
    }

    /// `PATCH /rest/v1/reviews?id=eq.<review_id>` with the whole set (contract #61).
    public func setTags(reviewID: UUID, tags: [DietTag]) async throws {
        _ = try await api.supabase
            .from("reviews")
            .update(ReviewTagsPatch(tags: tags), returning: .minimal)
            .eq("id", value: reviewID.uuidString.lowercased())
            .execute()
    }

    public func updateBody(entryID: UUID, body: String) async throws {
        _ = try await api.supabase
            .from("entries")
            .update(["body": body], returning: .minimal)
            .eq("id", value: entryID.uuidString.lowercased())
            .execute()
    }

    // MARK: - When, and which photo

    public func setEntryDate(entryID: UUID, eatenAt: Date) async throws {
        let parameters: [String: AnyJSON] = [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_eaten_at": .string(PostgRESTTimestamp.string(from: eatenAt))
        ]
        do {
            _ = try await api.supabase.rpc("set_entry_date", params: parameters).execute()
        } catch let error as PostgrestError where error.code == "PGRST202" {
            // A server without 0063 has no such function: the rest of the edit still saves, and the
            // entry keeps the day it had.
            return
        }
    }

    /// Only with a live session, refreshed first if it has lapsed (``AteAPIClient/session()``). Without
    /// one the call goes out on the publishable key alone and match-photos answers 401 — 27 Oct, a
    /// signed-out viewer opening photos (``matchPhotosIfNeverMatched``) did, over and over. Nothing to
    /// match for someone who is not signed in: skip it.
    private func hasSession() async -> Bool {
        (try? await api.session()) != nil
    }

    public func matchPhotos(entryID: UUID) async {
        guard await hasSession() else { return }
        _ = try? await api.supabase.functions.invoke(
            "match-photos",
            options: FunctionInvokeOptions(method: .post, body: ["entry_id": entryID.uuidString.lowercased()])
        ) { _, _ in () }
    }

    public func matchPhotosIfNeverMatched(entryID: UUID) async {
        let body: [String: AnyJSON] = [
            "entry_id": .string(entryID.uuidString.lowercased()),
            "unmatched_only": .bool(true)
        ]
        guard await hasSession() else { return }
        _ = try? await api.supabase.functions.invoke(
            "match-photos",
            options: FunctionInvokeOptions(method: .post, body: body)
        ) { _, _ in () }
    }

    public func setReviewPhoto(entryID: UUID, photoURL: String, reviewID: UUID?) async throws {
        let parameters: [String: AnyJSON] = [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_photo_url": .string(photoURL),
            "p_review_id": reviewID.map { AnyJSON.string($0.uuidString.lowercased()) } ?? .null
        ]
        _ = try await api.supabase.rpc("set_review_photo", params: parameters).execute()
    }

    public func photoDishes(entryID: UUID) async throws -> [String: UUID] {
        try await photoDishTags(entryID: entryID).mapValues { $0[0].reviewID }
    }

    /// One read per entry (PK entry_id, photo_url, review_id): at most five photos × its lines.
    public func photoDishTags(entryID: UUID) async throws -> [String: [PhotoDishTag]] {
        let data = try await api.supabase
            .from("photo_dishes")
            .select("photo_url, review_id, box_left, box_top, box_right, box_bottom")
            .eq("entry_id", value: entryID.uuidString.lowercased())
            .order("created_at")
            .order("review_id")
            .execute()
            .data
        return try PhotoDishRow.tags(from: data)
    }

    /// One read for a screenful of entries (the PK leads with entry_id): at most five photos × its
    /// lines each.
    public func photoDishTags(entryIDs: [UUID]) async throws -> [UUID: [String: [PhotoDishTag]]] {
        guard entryIDs.isEmpty == false else { return [:] }
        let data = try await api.supabase
            .from("photo_dishes")
            .select("entry_id, photo_url, review_id, box_left, box_top, box_right, box_bottom")
            .in("entry_id", values: entryIDs.map { $0.uuidString.lowercased() })
            .order("created_at")
            .order("review_id")
            .execute()
            .data
        return try PhotoDishRow.tagsByEntry(from: data)
    }

    public func setPhotoDishes(entryID: UUID, photoURL: String, reviewIDs: [UUID]) async throws {
        let parameters: [String: AnyJSON] = [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_photo_url": .string(photoURL),
            "p_review_ids": .array(reviewIDs.map { .string($0.uuidString.lowercased()) })
        ]
        _ = try await api.supabase.rpc("set_photo_dishes", params: parameters).execute()
    }

    // MARK: - Delete

    /// `rpc delete_entry(p_entry_id) → {photo_paths}`, then the files. The row is the delete: once
    /// the RPC has answered the entry is gone, so a storage failure is not the person's problem —
    /// an orphaned file costs bytes, an entry that refuses to go costs trust.
    @discardableResult
    public func delete(entryID: UUID) async throws -> EntryDeletion {
        let data: Data
        do {
            data = try await api.supabase
                .rpc("delete_entry", params: ["p_entry_id": AnyJSON.string(entryID.uuidString.lowercased())])
                .execute()
                .data
        } catch {
            // `P0002`: no such entry — already deleted (a second tap, another device). The person
            // asked for it to be gone, and it is (0037).
            guard EntryDeletion.isAlreadyGone(code: (error as? PostgrestError)?.code) else { throw error }
            return EntryDeletion(photoPaths: [])
        }
        let deletion = try EntryDeletion.decode(data)
        let files = deletion.storageFiles
        if files.isEmpty == false {
            try? await api.removePhotos(bucket: EntryDeletion.bucket, paths: files)
        }
        return deletion
    }

    // MARK: - Wire

    private func isDuplicateKey(_ error: any Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }

    private struct EntryPhotoRow: Encodable, Sendable {
        let entryID: UUID
        let position: Int
        let photoURL: String

        enum CodingKeys: String, CodingKey {
            case position
            case entryID = "entry_id"
            case photoURL = "photo_url"
        }
    }

    /// `sort-entry` with `"preview": true` — body, tag chips and place; no entry id, nothing written.
    struct PreviewSortRequest: Encodable, Sendable {
        let body: String
        let tagTokens: [TagToken]
        let scoreTokens: [TagToken]
        let restaurantID: UUID

        init(_ input: EarlySortInput) {
            body = input.body
            tagTokens = input.tagTokens
            scoreTokens = input.scoreTokens
            restaurantID = input.restaurantID
        }

        enum CodingKeys: String, CodingKey {
            case preview, body
            case tagTokens = "tag_tokens"
            case sixTokens = "six_tokens"
            case scoreTokens = "score_tokens"
            case restaurantID = "restaurant_id"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .preview)
            try container.encode(body, forKey: .body)
            try container.encode(tagTokens, forKey: .tagTokens)
            try container.encode(scoreTokens, forKey: .scoreTokens)
            if scoreTokens.isEmpty == false {
                try container.encode(scoreTokens, forKey: .sixTokens)
            }
            try container.encode(restaurantID.uuidString.lowercased(), forKey: .restaurantID)
        }
    }

    /// The plan comes back; nothing on this side reads it — the point is the server's cache.
    private struct PreviewResponse: Decodable, Sendable {
        let ok: Bool?
    }

    /// The sort's reply, read with ``PostgRESTDate/decoder`` — `entry_card` carries the view's
    /// microsecond timestamps.
    static func decodeSortResponse(_ data: Data) throws -> SortResponse {
        try PostgRESTDate.decoder.decode(SortResponse.self, from: data)
    }

    struct SortResponse: Decodable, Sendable {
        let ok: Bool?
        let mode: String?
        let sortStatus: String?
        let restaurantID: String?
        /// Only the count is used; the receipt is drawn from ``entryCard`` — the `entry_cards` row,
        /// the one row shape and the only thing allowed to say what an entry contains.
        let items: [SortResponseItem]?
        /// 0056. Lenient: a card this build cannot read is a re-read, never a failed sort.
        let entryCard: LenientCard?

        enum CodingKeys: String, CodingKey {
            case ok, mode, items
            case sortStatus = "sort_status"
            case restaurantID = "restaurant_id"
            case entryCard = "entry_card"
        }
    }

    struct LenientCard: Decodable, Sendable {
        let card: EntryCard?

        init(from decoder: any Decoder) throws {
            card = try? EntryCard(from: decoder)
        }
    }

    /// Deliberately no `tags`: a forced re-sort answers `items[].tags: []` while the database keeps
    /// each line's inherited set, so a line's tags are read from `entry_cards` and nowhere else.
    struct SortResponseItem: Decodable, Sendable {
        let dishName: String?

        enum CodingKeys: String, CodingKey {
            case dishName = "dish_name"
        }
    }
}

extension SupabaseEntryService {
    /// `…/storage/v1/object/public/review-photos/<path>` → `<path>`, and the same for a photo on R2
    /// (`https://photos.<domain>/review-photos/<path>`, 0101). Anything else is not ours: `nil`.
    static func storagePath(fromPublicURL url: String) -> String? {
        let marker = "/object/public/\(photoBucket)/"
        if let range = url.range(of: marker) {
            let path = String(url[range.upperBound...])
            return path.isEmpty ? nil : path.removingPercentEncoding ?? path
        }
        let prefix = "/\(photoBucket)/"
        guard let parsed = URL(string: url), let host = parsed.host(), PhotoHosts.isPhotoHost(host),
              parsed.path().hasPrefix(prefix) else { return nil }
        let path = String(parsed.path().dropFirst(prefix.count))
        return path.isEmpty ? nil : path.removingPercentEncoding ?? path
    }
}
