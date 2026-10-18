import Foundation
import PostgREST

/// **Your lists** (0060): a name and your own dish lines, in hand order. Private, signed in only.
///
/// One protocol, two implementations — Supabase, and memory for previews, tests and
/// `-ate-preview-data`. Both throw ``ListsError``, so a store reads one set of refusals.
public protocol ListsServing: Sendable {
    /// `my_lists(p_with_shared: true)` — your lists and the ones you accepted, newest shelved first,
    /// keyset `(shelved_at, list_id)`. At most 50 a page.
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

    // MARK: Covers and people (0073)

    /// `set_list_cover` — an upload goes to `review-photos/<you>/list-covers/` first. Answers the
    /// resolved cover (`nil` = automatic).
    func setCover(listID: UUID, choice: ListCoverChoice) async throws -> String?
    /// `list_people` — the owner sees everyone invited or accepted; a member, the accepted.
    func people(listID: UUID) async throws -> [ListPerson]
    /// `set_list_people` — the WHOLE set wanted on the list (sent as ids): new people are invited,
    /// the rest taken off. `peopleCap` past 20.
    func setPeople(listID: UUID, people: [ListPerson]) async throws -> [ListPerson]
    /// `my_list_invites` — unanswered invitations, newest first.
    func invites() async throws -> [ListInvite]
    /// `respond_list_invite` — accept puts the list on your shelf; decline is silent. `inviteNotFound`
    /// when it was withdrawn meanwhile.
    func respond(toInvite listID: UUID, accept: Bool) async throws
    /// `leave_list` — off someone else's list. Already off counts as done.
    func leave(listID: UUID) async throws
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
    /// People on one list besides its owner (0073).
    public static let peopleCap = 20

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
    /// `54000 list_people_cap` — 20 people on one list.
    case peopleCap
    /// `P0002 invite_not_found` — the invitation was withdrawn, or already answered.
    case inviteNotFound
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
        case "42501": self = .signedOut
        case let code?:
            guard let reading = Self.readings[code] else {
                self = .unreachable
                return
            }
            self = reading.named.first { message.contains($0.marker) }?.error ?? reading.otherwise
        case nil: self = .unreachable
        }
    }

    /// Each code's named refusals, checked in order, and what the code means when none is named.
    private static let readings: [String: (named: [(marker: String, error: ListsError)], otherwise: ListsError)] = [
        "54000": ([("list_item_cap", .itemCap), ("list_people_cap", .peopleCap)], .listCap),
        "22023": ([("bad_list_name", .badName), ("reorder_mismatch", .reorderMismatch)], .badInput),
        "P0002": ([("dish_line_not_found", .lineNotFound), ("invite_not_found", .inviteNotFound)], .listNotFound),
    ]

    /// A cap: the one refusal the screens explain rather than quietly undo.
    public var isCap: Bool { self == .listCap || self == .itemCap || self == .peopleCap }
}
