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
        do {
            let response = try await api.supabase
                .from("entries")
                .insert(entry, returning: .minimal)
                .execute()
            _ = response
        } catch {
            // `23505` on an entry insert means the entry already landed: the id is the client's, so
            // the row that is there is ours. Treat it as the success it is (contract, Errors).
            guard isDuplicateKey(error) else { throw EntryWriteFailure.of(error) }
        }
        return try await self.entry(id: entry.id)
    }

    public func attach(photo: EntryPhotoUpload) async throws {
        let userID = try await api.requireCurrentUserID()
        let path = "\(userID.uuidString.lowercased())/\(photo.entryID.uuidString.lowercased())"
            + "-\(photo.position).jpg"
        let storage = api.supabase.storage.from("review-photos")
        // `upsert` so a retried upload overwrites rather than 409s — the path is deterministic, so
        // a second attempt is the same object.
        _ = try await storage.upload(
            path,
            data: photo.data,
            options: FileOptions(contentType: "image/jpeg", upsert: true)
        )
        let url = try storage.getPublicURL(path: path).absoluteString
        _ = try await api.supabase
            .from("entry_photos")
            .upsert(
                EntryPhotoRow(entryID: photo.entryID, position: photo.position, photoURL: url),
                onConflict: "entry_id,position",
                returning: .minimal
            )
            .execute()
    }

    @discardableResult
    public func sort(entryID: UUID, force: Bool) async throws -> SortOutcome {
        let response: SortResponse = try await api.supabase.functions.invoke(
            "sort-entry",
            options: FunctionInvokeOptions(
                method: .post,
                body: SortRequest(entryID: entryID, force: force, dryRun: false)
            )
        )
        return SortOutcome(
            entryID: entryID,
            status: EntrySortStatus(rawValue: response.sortStatus ?? "sorted") ?? .sorted,
            mode: response.mode ?? "stub",
            itemCount: response.items?.count ?? 0,
            restaurantID: response.restaurantID.flatMap(UUID.init(uuidString:)),
            didAttachPlace: response.restaurantID != nil
        )
    }

    // MARK: - Read

    public func entry(id: UUID) async throws -> EntryCard {
        let data = try await api.supabase
            .from(EntryCard.table)
            .select(EntryCard.columns)
            .eq("id", value: id.uuidString.lowercased())
            .limit(1)
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

    public func setVisibility(entryID: UUID, visibility: EntryVisibility) async throws {
        _ = try await api.supabase
            .from("entries")
            .update(["visibility": visibility.rawValue], returning: .minimal)
            .eq("id", value: entryID.uuidString.lowercased())
            .execute()
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

    private struct SortRequest: Encodable, Sendable {
        let entryID: UUID
        let force: Bool
        let dryRun: Bool

        enum CodingKeys: String, CodingKey {
            case force
            case entryID = "entry_id"
            case dryRun = "dry_run"
        }
    }

    private struct SortResponse: Decodable, Sendable {
        let ok: Bool?
        let mode: String?
        let sortStatus: String?
        let restaurantID: String?
        /// Only the count is used; the receipt itself is refetched from `entry_cards`, which is the
        /// one row shape and the only thing allowed to say what an entry contains.
        let items: [SortResponseItem]?

        enum CodingKeys: String, CodingKey {
            case ok, mode, items
            case sortStatus = "sort_status"
            case restaurantID = "restaurant_id"
        }
    }

    private struct SortResponseItem: Decodable, Sendable {
        let dishName: String?

        enum CodingKeys: String, CodingKey {
            case dishName = "dish_name"
        }
    }
}
