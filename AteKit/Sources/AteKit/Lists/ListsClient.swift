import Foundation
import PostgREST
import Supabase

/// **The live lists** — the 0060 RPCs, all thin. Rows decode with ``PostgRESTDate/decoder``
/// (microsecond timestamps keep the keyset exact); every refusal comes back as ``ListsError``.
public struct ListsClient: ListsServing {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func myLists(after cursor: PageCursor?, limit: Int) async throws -> UserListPage {
        let clamped = min(ListRules.listCap, max(1, limit))
        let rows: [UserList] = try await call("my_lists", [
            "p_limit": .integer(clamped),
            // Both halves of the keyset, or neither.
            "p_cursor_created_at": cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null,
            "p_cursor_id": cursor.map { .string(Self.id($0.id)) } ?? .null
        ])
        return UserListPage(items: rows, requestedLimit: clamped)
    }

    public func list(id: UUID) async throws -> ListDetail {
        try await call("get_list", ["p_list_id": .string(Self.id(id))])
    }

    public func createList(name: String) async throws -> UserList {
        let rows: [UserList] = try await call("create_list", ["p_name": .string(name)])
        guard let row = rows.first else { throw ListsError.unreachable }
        return row
    }

    public func renameList(id: UUID, name: String) async throws -> UserList {
        let rows: [UserList] = try await call("rename_list", [
            "p_list_id": .string(Self.id(id)), "p_name": .string(name)
        ])
        guard let row = rows.first else { throw ListsError.listNotFound }
        return row
    }

    public func deleteList(id: UUID) async throws {
        let _: Int = try await call("delete_list", ["p_list_id": .string(Self.id(id))])
    }

    public func addItem(listID: UUID, line: DishLine) async throws -> ListItemReceipt {
        let rows: [ListItemReceipt] = try await call("add_list_item", [
            "p_list_id": .string(Self.id(listID)),
            "p_entry_id": .string(Self.id(line.entryID)),
            "p_dish_id": .string(Self.id(line.dishID))
        ])
        guard let row = rows.first else { throw ListsError.lineNotFound }
        return row
    }

    public func removeItem(itemID: UUID) async throws {
        let _: Int = try await call("remove_list_item", ["p_item_id": .string(Self.id(itemID))])
    }

    public func reorder(listID: UUID, itemIDs: [UUID]) async throws {
        let _: Int = try await call("reorder_list", [
            "p_list_id": .string(Self.id(listID)),
            "p_item_ids": .array(itemIDs.map { .string(Self.id($0)) })
        ])
    }

    public func lists(containing line: DishLine) async throws -> [ListMembership] {
        try await call("my_lists_for_dish_line", [
            "p_entry_id": .string(Self.id(line.entryID)), "p_dish_id": .string(Self.id(line.dishID))
        ])
    }

    public func myDishLines(
        query: String?, scoredOnly: Bool, listID: UUID?, after cursor: ListPickerCursor?, limit: Int
    ) async throws -> ListPickerPage {
        let clamped = min(PageRequest.maximumLimit, max(1, limit))
        let rows: [ListPickerDish] = try await call("my_scored_dishes", Self.pickerParameters(
            query: query, scoredOnly: scoredOnly, listID: listID, after: cursor, limit: clamped
        ))
        return ListPickerPage(items: rows, requestedLimit: clamped)
    }

    // MARK: - Wire

    /// `my_scored_dishes`' arguments: the query trimmed and capped at 100 characters on the phone too,
    /// and all three cursor fields or none.
    static func pickerParameters(
        query: String?, scoredOnly: Bool, listID: UUID?, after cursor: ListPickerCursor?, limit: Int
    ) -> [String: AnyJSON] {
        [
            "p_query": ListRules.query(query).map { .string($0) } ?? .null,
            "p_scored_only": .bool(scoredOnly),
            "p_list_id": listID.map { .string(id($0)) } ?? .null,
            "p_limit": .integer(limit),
            "p_cursor_visited_at": cursor.map { .string(PostgRESTTimestamp.string(from: $0.visitedAt)) } ?? .null,
            "p_cursor_entry_id": cursor.map { .string(id($0.entryID)) } ?? .null,
            "p_cursor_dish_id": cursor.map { .string(id($0.dishID)) } ?? .null
        ]
    }

    private static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    private func call<T: Decodable>(_ function: String, _ parameters: [String: AnyJSON]) async throws -> T {
        do {
            let data = try await api.supabase.rpc(function, params: parameters).execute().data
            return try PostgRESTDate.decoder.decode(T.self, from: data)
        } catch {
            throw ListsError.of(error)
        }
    }
}
