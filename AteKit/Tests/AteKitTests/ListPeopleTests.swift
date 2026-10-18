import Foundation
import PostgREST
import Testing
@testable import AteKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try PostgRESTDate.decoder.decode(T.self, from: Data(json.utf8))
}

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private let eamon = ListPerson(id: UUID(), username: "eamon")
private let paris = ListPerson(id: UUID(), username: "paris")
private let jules = ListPerson(id: UUID(), username: "jules")

@Suite("Lists — covers and people (0073) payloads")
struct ListPeopleDecodingTests {
    @Test("my_lists: a shared list carries its owner, the custom cover and the shelf key")
    func sharedRow() throws {
        let rows = try decode([UserList].self, """
        [{"list_id": "1A000000-0000-4000-8000-000000000001", "name": "Date night", "visibility": "private",
          "item_count": 6, "covers": ["https://x/1.jpg"], "cover_url": "https://x/cover.jpg?v=1",
          "is_own": false, "owner": {"id": "1B000000-0000-4000-8000-000000000001", "username": "eamon",
          "name": null, "avatar_url": "https://x/a.jpg"},
          "created_at": "2026-10-01T09:00:00+00:00", "updated_at": "2026-10-04T10:00:00+00:00",
          "shelved_at": "2026-10-18T09:00:00.123456+00:00"}]
        """)
        let row = try #require(rows.first)
        #expect(row.isOwn == false)
        #expect(row.owner?.username == "eamon" && row.owner?.avatarURL == "https://x/a.jpg")
        #expect(row.coverURL == "https://x/cover.jpg?v=1")
        #expect(PostgRESTTimestamp.string(from: row.cursor.createdAt) == "2026-10-18T09:00:00.123456Z")
    }

    @Test("an older row without 0073's columns is your own, automatic, shelved when made")
    func olderRow() throws {
        let row = try #require(try decode([UserList].self, """
        [{"list_id": "1A000000-0000-4000-8000-000000000002", "name": "Pho", "visibility": "private",
          "item_count": 0, "created_at": "2026-10-05T09:00:00+00:00", "updated_at": "2026-10-05T09:00:00+00:00"}]
        """).first)
        #expect(row.isOwn && row.coverURL == nil && row.owner == nil)
        #expect(row.shelvedAt == row.createdAt)
    }

    @Test("get_list: the role, the people, the picked cover item")
    func detail() throws {
        let detail = try decode(ListDetail.self, """
        {"list_id": "1A000000-0000-4000-8000-000000000003", "name": "Date night", "visibility": "private",
         "created_at": "2026-10-01T09:00:00+00:00", "updated_at": "2026-10-01T09:00:00+00:00", "item_count": 0,
         "covers": [], "cover_url": "https://x/1.jpg", "cover_item_id": "1C000000-0000-4000-8000-000000000001",
         "is_own": false, "membership": "accepted",
         "owner": {"id": "1B000000-0000-4000-8000-000000000001", "username": "eamon", "avatar_url": null},
         "people": [{"id": "1B000000-0000-4000-8000-000000000002", "username": "paris", "avatar_url": null,
                     "status": "accepted"}],
         "items": []}
        """)
        #expect(detail.role == .accepted && detail.isOwn == false)
        #expect(detail.people.map(\.username) == ["paris"])
        #expect(detail.list.coverItemID?.uuidString == "1C000000-0000-4000-8000-000000000001")
    }

    @Test("list_people names the id user_id; my_list_invites carries the owner")
    func peopleAndInvites() throws {
        let people = try decode([ListPerson].self, """
        [{"user_id": "1B000000-0000-4000-8000-000000000002", "username": "paris", "name": null,
          "avatar_url": null, "status": "invited", "invited_at": "2026-10-18T09:00:00+00:00"}]
        """)
        #expect(people.first?.status == .invited)
        let invites = try decode([ListInvite].self, """
        [{"list_id": "1A000000-0000-4000-8000-000000000003", "name": "Date night", "item_count": 6,
          "covers": [], "cover_url": null,
          "owner": {"id": "1B000000-0000-4000-8000-000000000001", "username": "eamon", "avatar_url": null},
          "invited_at": "2026-10-18T09:00:00+00:00"}]
        """)
        #expect(invites.first?.owner.username == "eamon" && invites.first?.itemCount == 6)
    }

    @Test("refusals: the people cap and a withdrawn invite")
    func errors() {
        #expect(ListsError(code: "54000", message: "list_people_cap") == .peopleCap)
        #expect(ListsError(code: "P0002", message: "invite_not_found") == .inviteNotFound)
        #expect(ListsError(code: "P0002", message: "list_not_found") == .listNotFound)
        #expect(ListsError.peopleCap.isCap)
    }
}

@MainActor
@Suite("Lists — covers and people (0073)")
struct ListPeopleStoreTests {
    private func open(photos: [String?] = ["p0", "p1", nil]) async -> (InMemoryLists, ListStore, ListsStore) {
        let lines = photos.enumerated().map { pickerLine("Dish \($0.offset)", daysAgo: $0.offset, photo: $0.element) }
        let service = InMemoryLists(lines: lines)
        let id = service.seed(name: "Date night", lines: lines.map(\.line), createdAt: base)
        let shelf = ListsStore(service: service)
        await shelf.refresh()
        let store = ListStore(listID: id, service: service, shelf: shelf)
        await store.refresh()
        return (service, store, shelf)
    }

    @Test("a dish cover shows at once, reaches the shelf, and goes automatic when its item leaves")
    func dishCover() async throws {
        let (_, store, shelf) = await open()
        #expect(store.coverCandidates.map(\.dishName) == ["Dish 0", "Dish 1"], "only photos, once each")
        let pick = try #require(store.items.first { $0.dishName == "Dish 1" })
        #expect(await store.setCover(.item(pick.id)))
        #expect(store.list?.coverURL == "p1")
        #expect(shelf.lists.first?.coverURL == "p1")
        await store.remove(pick)
        #expect(store.list?.coverURL == nil, "its item left: automatic")
        #expect(shelf.lists.first?.coverURL == nil)
    }

    @Test("an upload lands as the server's URL; automatic clears it; a refusal puts the old one back")
    func uploadCover() async {
        let (service, store, _) = await open()
        #expect(await store.setCover(.upload(AvatarUpload(data: Data([1, 2, 3])))))
        let uploaded = store.list?.coverURL
        #expect(uploaded?.contains("list-covers") == true)
        service.failNext(.unreachable)
        #expect(await store.setCover(.automatic) == false)
        #expect(store.list?.coverURL == uploaded)
        #expect(await store.setCover(.automatic))
        #expect(store.list?.coverURL == nil)
    }

    @Test("people: the whole set is sent; new ones are invited; the cap is refused before asking")
    func people() async {
        let (service, store, _) = await open()
        #expect(await store.setPeople([paris, jules]))
        #expect(store.people.map(\.status) == [.invited, .invited])
        #expect(await store.setPeople([paris]))
        #expect(store.people.map(\.username) == ["paris"])
        let crowd = (0...ListRules.peopleCap).map { ListPerson(id: UUID(), username: "p\($0)") }
        let calls = service.calls.count
        #expect(await store.setPeople(crowd) == false)
        #expect(store.failure == .peopleCap && service.calls.count == calls)
    }

    @Test("an invite: preview, accept onto the shelf, open as a viewer, leave")
    func invite() async throws {
        let service = InMemoryLists()
        let listID = UUID()
        service.seedInvite(ListInvite(listID: listID, name: "Date night", itemCount: 6, owner: eamon, invitedAt: base))
        let shelf = ListsStore(service: service)
        await shelf.refresh()
        #expect(shelf.lists.isEmpty)
        let invites = ListInvitesStore(service: service, shelf: shelf, now: { base.addingTimeInterval(60) })
        await invites.refresh()
        #expect(invites.invites.map(\.name) == ["Date night"])

        let invite = try #require(invites.invites.first)
        #expect(await invites.respond(to: invite, accept: true))
        #expect(invites.invites.isEmpty)
        #expect(shelf.lists.first?.id == listID && shelf.lists.first?.isOwn == false)
        #expect(shelf.lists.first?.owner?.username == "eamon")

        let store = ListStore(listID: listID, list: shelf.lists.first, service: service, shelf: shelf)
        #expect(store.isOwn == false, "a viewer before the first read")
        await store.refresh()
        #expect(store.role == .accepted)
        #expect(await store.setCover(.automatic) == false, "never the viewer's to change")
        #expect(await store.leave())
        #expect(store.phase == .gone && shelf.lists.isEmpty)
    }

    @Test("decline is silent; a withdrawn invite stays gone")
    func decline() async throws {
        let service = InMemoryLists()
        let first = ListInvite(listID: UUID(), name: "A", itemCount: 1, owner: eamon, invitedAt: base)
        let second = ListInvite(listID: UUID(), name: "B", itemCount: 1, owner: eamon, invitedAt: base)
        service.seedInvite(first)
        service.seedInvite(second)
        let invites = ListInvitesStore(service: service)
        await invites.refresh()
        #expect(await invites.respond(to: first, accept: false))
        service.failNext(.inviteNotFound)
        #expect(await invites.respond(to: second, accept: true) == false)
        #expect(invites.invites.isEmpty && invites.failure == .inviteNotFound)
    }
}
