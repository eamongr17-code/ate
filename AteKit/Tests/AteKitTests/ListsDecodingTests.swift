import Foundation
import PostgREST
import Supabase
import Testing
@testable import AteKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try PostgRESTDate.decoder.decode(T.self, from: Data(json.utf8))
}

@Suite("Lists — 0060 payloads")
struct ListsDecodingTests {
    @Test("my_lists: name, count, up to four covers, the two-part keyset")
    func myListsRow() throws {
        let rows = try decode([UserList].self, """
        [{"list_id": "1A000000-0000-4000-8000-000000000001", "name": "Melbourne\u{2019}s best burgers",
          "visibility": "private", "item_count": 6,
          "covers": ["https://x/1.jpg", "https://x/2.jpg", "https://x/3.jpg", "https://x/4.jpg"],
          "created_at": "2026-10-01T09:00:00.123456+00:00", "updated_at": "2026-10-04T10:00:00+00:00"},
         {"list_id": "1A000000-0000-4000-8000-000000000002", "name": "Date night", "visibility": "private",
          "item_count": 0, "covers": [], "created_at": "2026-09-30T09:00:00+00:00",
          "updated_at": "2026-09-30T09:00:00+00:00"}]
        """)
        #expect(rows.map(\.name) == ["Melbourne\u{2019}s best burgers", "Date night"])
        #expect(rows[0].itemCount == 6 && rows[0].covers.count == 4)
        #expect(rows[1].covers.isEmpty)
        #expect(rows[0].cursor.id == rows[0].id)
        #expect(PostgRESTTimestamp.string(from: rows[0].cursor.createdAt) == "2026-10-01T09:00:00.123456Z")
    }

    @Test("create_list and rename_list answer without covers, which is none")
    func createRow() throws {
        let rows = try decode([UserList].self, """
        [{"list_id": "1A000000-0000-4000-8000-000000000003", "name": "Pho", "visibility": "private",
          "item_count": 0, "created_at": "2026-10-05T09:00:00+00:00", "updated_at": "2026-10-05T09:00:00+00:00"}]
        """)
        #expect(rows.first?.covers == [])
        #expect(rows.first?.itemCount == 0)
    }

    @Test("get_list: the list, its items in order, scores (null = unscored), covers from item photos")
    func getList() throws {
        let detail = try decode(ListDetail.self, """
        {"list_id": "1A000000-0000-4000-8000-000000000001", "name": "Burgers", "visibility": "private",
         "item_count": 3, "created_at": "2026-10-01T09:00:00+00:00", "updated_at": "2026-10-04T10:00:00+00:00",
         "items": [
          {"item_id": "11000000-0000-4000-8000-000000000002", "position": 2,
           "entry_id": "E0000000-0000-4000-8000-000000000002", "dish_id": "D0000000-0000-4000-8000-000000000002",
           "dish_name": "Smash burger", "restaurant_id": "B0000000-0000-4000-8000-000000000002",
           "restaurant_name": "Rockwell & Sons", "locality": "Collingwood", "score": null,
           "photo_url": "https://x/a.jpg", "visited_at": "2026-09-20T09:00:00+00:00",
           "added_at": "2026-10-01T09:00:00+00:00"},
          {"item_id": "11000000-0000-4000-8000-000000000001", "position": 1,
           "entry_id": "E0000000-0000-4000-8000-000000000001", "dish_id": "D0000000-0000-4000-8000-000000000001",
           "dish_name": "Double cheeseburger", "restaurant_id": "B0000000-0000-4000-8000-000000000001",
           "restaurant_name": "Royal Stacks", "locality": null, "score": 6,
           "photo_url": "https://x/a.jpg", "visited_at": "2026-09-22T09:00:00+00:00",
           "added_at": "2026-10-01T09:00:00+00:00"},
          {"item_id": "11000000-0000-4000-8000-000000000003", "position": 3,
           "entry_id": "E0000000-0000-4000-8000-000000000003", "dish_id": "D0000000-0000-4000-8000-000000000003",
           "dish_name": "The Classic", "restaurant_id": "B0000000-0000-4000-8000-000000000003",
           "restaurant_name": "Easey\u{2019}s", "locality": "Collingwood", "score": 4.5,
           "photo_url": null, "visited_at": "2026-09-10T09:00:00+00:00",
           "added_at": "2026-10-02T09:00:00+00:00"}]}
        """)
        #expect(detail.items.map(\.position) == [1, 2, 3])
        #expect(detail.items.map(\.dishName) == ["Double cheeseburger", "Smash burger", "The Classic"])
        #expect(detail.items[0].score == .blownAway)
        #expect(detail.items[1].score == nil, "unscored stays unscored")
        #expect(detail.items[0].locality == nil)
        #expect(detail.list.itemCount == 3)
        #expect(detail.list.covers == ["https://x/a.jpg"], "distinct photos, list order")
    }

    @Test("an empty list's items are []")
    func emptyList() throws {
        let detail = try decode(ListDetail.self, """
        {"list_id": "1A000000-0000-4000-8000-000000000002", "name": "Date night", "visibility": "private",
         "item_count": 0, "created_at": "2026-10-01T09:00:00+00:00", "updated_at": "2026-10-01T09:00:00+00:00",
         "items": []}
        """)
        #expect(detail.items.isEmpty && detail.list.covers.isEmpty)
    }

    @Test("my_scored_dishes: one row per visit and dish, its own keyset, in_list")
    func pickerRow() throws {
        let rows = try decode([ListPickerDish].self, """
        [{"entry_id": "E0000000-0000-4000-8000-000000000001", "dish_id": "D0000000-0000-4000-8000-000000000001",
          "dish_name": "Tagliatelle al rag\u{f9}", "restaurant_id": "B0000000-0000-4000-8000-000000000001",
          "restaurant_name": "Tipo 00", "locality": "CBD", "score": 4.5, "photo_url": null,
          "visited_at": "2026-09-19T10:14:00.000001+00:00", "in_list": true},
         {"entry_id": "E0000000-0000-4000-8000-000000000002", "dish_id": "D0000000-0000-4000-8000-000000000002",
          "dish_name": "Prawn spaghetti", "restaurant_id": "B0000000-0000-4000-8000-000000000001",
          "restaurant_name": "Tipo 00", "locality": "CBD", "score": null, "photo_url": "https://x/p.jpg",
          "visited_at": "2026-09-19T10:14:00+00:00", "in_list": false}]
        """)
        #expect(rows[0].inList && rows[1].inList == false)
        #expect(rows[1].score == nil)
        #expect(rows[0].cursor.entryID == rows[0].entryID && rows[0].cursor.dishID == rows[0].dishID)
        #expect(rows[0].id == DishLine(entryID: rows[0].entryID, dishID: rows[0].dishID))
    }

    @Test("my_lists_for_dish_line: item_id says whether the line is on it")
    func membershipRow() throws {
        let rows = try decode([ListMembership].self, """
        [{"list_id": "1A000000-0000-4000-8000-000000000001", "name": "Burgers", "item_count": 6,
          "item_id": "11000000-0000-4000-8000-000000000001"},
         {"list_id": "1A000000-0000-4000-8000-000000000002", "name": "Date night", "item_count": 0, "item_id": null}]
        """)
        #expect(rows.map(\.contains) == [true, false])
    }

    @Test("add_list_item answers the item and where it sits")
    func receipt() throws {
        let rows = try decode([ListItemReceipt].self, """
        [{"item_id": "11000000-0000-4000-8000-000000000009", "list_id": "1A000000-0000-4000-8000-000000000001",
          "entry_id": "E0000000-0000-4000-8000-000000000001", "dish_id": "D0000000-0000-4000-8000-000000000001",
          "item_position": 7, "added_at": "2026-10-05T09:00:00+00:00"}]
        """)
        #expect(rows.first?.position == 7)
    }

    @Test("the server's codes become typed refusals: caps, names, reorder, gone, signed out")
    func errors() {
        #expect(ListsError.of(PostgrestError(code: "54000", message: "list_cap")) == .listCap)
        #expect(ListsError.of(PostgrestError(code: "54000", message: "list_item_cap")) == .itemCap)
        #expect(ListsError.of(PostgrestError(code: "22023", message: "bad_list_name")) == .badName)
        #expect(ListsError.of(PostgrestError(code: "22023", message: "reorder_mismatch")) == .reorderMismatch)
        #expect(ListsError.of(PostgrestError(code: "22023", message: "query_too_long")) == .badInput)
        #expect(ListsError.of(PostgrestError(code: "P0002", message: "list_not_found")) == .listNotFound)
        #expect(ListsError.of(PostgrestError(code: "P0002", message: "dish_line_not_found")) == .lineNotFound)
        #expect(ListsError.of(PostgrestError(code: "42501", message: "sign in to use lists")) == .signedOut)
        #expect(ListsError.of(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(ListsError.listCap.isCap && ListsError.itemCap.isCap && ListsError.badName.isCap == false)
    }

    @Test("names are trimmed to 1…80; queries are trimmed, cut to 100, and no filter under 2")
    func rules() {
        #expect(ListRules.name("  Pho  ") == "Pho")
        #expect(ListRules.name("   ") == nil)
        #expect(ListRules.name(String(repeating: "a", count: 80)) != nil)
        #expect(ListRules.name(String(repeating: "a", count: 81)) == nil)
        #expect(ListRules.query(" b ") == nil)
        #expect(ListRules.query(" bu ") == "bu")
        #expect(ListRules.query(String(repeating: "x", count: 140))?.count == 100)
    }

    @Test("the picker's wire: the query capped at 100, all three cursor fields or none")
    func pickerWire() {
        let first = ListsClient.pickerParameters(
            query: String(repeating: "q", count: 120), scoredOnly: true, listID: nil, after: nil, limit: 30
        )
        #expect(first["p_query"] == .string(String(repeating: "q", count: 100)))
        #expect(first["p_cursor_visited_at"] == .null && first["p_cursor_entry_id"] == .null
            && first["p_cursor_dish_id"] == .null)
        #expect(first["p_list_id"] == .null && first["p_scored_only"] == .bool(true))
        let cursor = ListPickerCursor(
            visitedAt: Date(timeIntervalSince1970: 1_789_812_840.25), entryID: UUID(), dishID: UUID()
        )
        let next = ListsClient.pickerParameters(query: "a", scoredOnly: false, listID: UUID(), after: cursor, limit: 30)
        #expect(next["p_query"] == .null, "one character is no filter")
        #expect(next["p_cursor_visited_at"] == .string("2026-09-19T10:14:00.250000Z"))
        #expect(next["p_cursor_entry_id"] == .string(cursor.entryID.uuidString.lowercased()))
        #expect(next["p_cursor_dish_id"] == .string(cursor.dishID.uuidString.lowercased()))
    }

    @Test("the events carry their names and counts, never names of lists or dishes")
    func events() {
        #expect(ListEvents.created().name == "list_created")
        #expect(ListEvents.renamed().name == "list_renamed")
        #expect(ListEvents.ctaTapped(from: .shelf).name == "list_cta_tapped")
        #expect(ListEvents.ctaTapped(from: .shelf).parameters == ["source": "shelf"])
        #expect(ListEvents.ctaTapped(from: .glass).parameters == ["source": "glass"])
        #expect(ListEvents.deleted(items: 6).parameters == ["items": "6"])
        #expect(ListEvents.itemAdded(count: 3, from: .picker).parameters == ["count": "3", "from": "picker"])
        #expect(ListEvents.itemRemoved(listSize: 5, undone: true).parameters["undone"] == "true")
        #expect(ListEvents.reordered(listSize: 6).name == "list_reordered")
        #expect(ListEvents.shared(lines: 6).name == "list_shared")
        #expect(JournalSearchEvents.opened().name == "journal_search_opened")
        #expect(JournalSearchEvents.searched(queryLength: 6, resultCount: 0).parameters["result_count"] == "0")
        #expect(JournalSearchEvents.resultOpened(position: 2).name == "journal_search_result_opened")
        #expect([0, 1, 2, 5, 6, 19, 20, 50].map(JournalSearchEvents.bucket)
            == ["0", "1", "2-5", "2-5", "6-19", "6-19", "20+", "20+"])
    }
}
