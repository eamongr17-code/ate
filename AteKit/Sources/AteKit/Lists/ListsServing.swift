import Foundation
import PostgREST

/// **Your lists** (0060): a name and your own dish lines, in hand order. Private, signed in only.
///
/// One protocol, two implementations — Supabase, and memory for previews, tests and
/// `-ate-preview-data`. Both throw ``ListsError``, so a store reads one set of refusals.
public protocol ListsServing: Sendable {
    /// `my_lists` — newest created first, keyset `(created_at, list_id)`. At most 50 a page.
    func myLists(after cursor: PageCursor?, limit: Int) async throws -> UserListPage
    /// `get_list` — the list and every item, in order.
    func list(id: UUID) async throws -> ListDetail
    /// `create_list` — a trimmed name of 1…80 characters. `listCap` past 50 lists.
    func createList(name: String) async throws -> UserList
    /// `rename_list`.
    func renameList(id: UUID, name: String) async throws -> UserList
    /// `delete_list` — already gone counts as done.
    func deleteList(id: UUID) async throws
    /// `add_list_item` — appended last; the same line again answers the same item. `itemCap` past 100.
    func addItem(listID: UUID, line: DishLine) async throws -> ListItemReceipt
    /// `remove_list_item` — already gone counts as done. Later items close up.
    func removeItem(itemID: UUID) async throws
    /// `reorder_list` — the FULL ordered array of the list's item ids, each once. Anything else is
    /// `reorderMismatch`: read the list again and reapply.
    func reorder(listID: UUID, itemIDs: [UUID]) async throws
    /// `my_lists_for_dish_line` — every list, and whether it holds this line.
    func lists(containing line: DishLine) async throws -> [ListMembership]
    /// `my_scored_dishes` — the picker: your lines, newest visit first. A query under two characters
    /// is no filter; over 100 is refused (the client trims it to 100 before asking).
    func myDishLines(query: String?, scoredOnly: Bool, listID: UUID?, after cursor: ListPickerCursor?, limit: Int)
        async throws -> ListPickerPage
}

public extension ListsServing {
    static var shelfPageSize: Int { 50 }
    static var pickerPageSize: Int { 30 }
}

/// **The server's list rules, on the phone** — the caps and the name and query bounds, so a store can
/// refuse before it asks and the in-memory service refuses exactly where the server would.
public enum ListRules {
    public static let listCap = 50
    public static let itemCap = 100
    public static let nameLimit = 80
    public static let queryLimit = 100
    public static let minimumQueryLength = 2

    /// The name the server will store: trimmed, 1…80 characters. `nil` is `bad_list_name`.
    public static func name(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= nameLimit else { return nil }
        return trimmed
    }

    /// The query to send: trimmed and cut to 100 characters (the server refuses a longer one). `nil`
    /// below two characters — the server's own "no filter".
    public static func query(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(queryLimit))
        return trimmed.count >= minimumQueryLength ? trimmed : nil
    }
}

/// **Every refusal a list call can meet**, by the server's codes and messages (0060).
public enum ListsError: Error, Sendable, Equatable {
    /// `54000 list_cap` — 50 lists.
    case listCap
    /// `54000 list_item_cap` — 100 items on one list.
    case itemCap
    /// `22023 bad_list_name` — empty or over 80 characters once trimmed.
    case badName
    /// `22023 reorder_mismatch` — the ids were not exactly the list's items.
    case reorderMismatch
    /// `22023` on a query over 100 characters, or a half cursor.
    case badInput
    /// `P0002 list_not_found` — gone, or not yours (indistinguishable).
    case listNotFound
    /// `P0002 dish_line_not_found` — not your entry, or the dish is no longer on it.
    case lineNotFound
    /// `42501` — signed out.
    case signedOut
    /// The network, or anything else the server did not explain.
    case unreachable

    /// Any error, read as one of these.
    public static func of(_ error: any Error) -> ListsError {
        if let error = error as? ListsError { return error }
        if let postgrest = error as? PostgrestError {
            return ListsError(code: postgrest.code, message: postgrest.message)
        }
        if (error as? AteAPIError) == .notAuthenticated { return .signedOut }
        return .unreachable
    }

    init(code: String?, message: String) {
        switch code {
        case "54000":
            self = message.contains("list_item_cap") ? .itemCap : .listCap
        case "22023":
            if message.contains("bad_list_name") {
                self = .badName
            } else if message.contains("reorder_mismatch") {
                self = .reorderMismatch
            } else {
                self = .badInput
            }
        case "P0002":
            self = message.contains("dish_line_not_found") ? .lineNotFound : .listNotFound
        case "42501":
            self = .signedOut
        default:
            self = .unreachable
        }
    }

    /// A cap: the one refusal the screens explain rather than quietly undo.
    public var isCap: Bool { self == .listCap || self == .itemCap }
}
