import Foundation
import Testing
@testable import AteKit

private final class FakeProfiles: ProfileReading, @unchecked Sendable {
    var summary: ProfileSummary?
    var entries: [EntryCard]
    var headerError: (any Error)?
    var blockFails = false
    private(set) var blocked: [UUID] = []
    private(set) var reportedProfiles: [UUID] = []
    private let lock = NSLock()

    init(summary: ProfileSummary?, entries: [EntryCard] = []) {
        self.summary = summary
        self.entries = entries
    }

    func profile(id: UUID) async throws -> ProfileSummary {
        if let headerError { throw headerError }
        guard let summary, lock.withLock({ blocked.contains(id) }) == false else {
            throw AteAPIError.notFound(table: "profiles", id: id)
        }
        return summary
    }

    func entriesPage(authorID: UUID, after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        let rows = lock.withLock { blocked.contains(authorID) ? [] : entries }
        return Page(items: rows.filter { $0.authorID == authorID }, requestedLimit: pageSize)
    }

    func block(userID: UUID) async throws {
        if blockFails { throw AteAPIError.notAuthenticated }
        lock.withLock { blocked.append(userID) }
    }

    func report(profileID: UUID, reason: String?, note: String?) async throws {
        lock.withLock { reportedProfiles.append(profileID) }
    }

    func report(entryID: UUID, reason: String?, note: String?) async throws {}
}

@MainActor
@Suite("Profile store")
struct ProfileStoreTests {

    private let userID = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!

    private var summary: ProfileSummary {
        ProfileSummary(userID: userID, username: "jessw", city: "Melbourne",
                       orders: 86, places: 40, dishes: 201)
    }

    private func entry() -> EntryCard {
        EntryCard(
            id: UUID(),
            authorID: userID,
            body: "Birthday pasta.",
            orderNumber: 86,
            sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_776_000),
            isMine: false,
            author: EntryCard.Author(id: userID, username: "jessw"),
            place: EntryCard.Place(id: UUID(), name: "Tipo 00"),
            items: [EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Prawn spaghetti",
                                   score: Rating(rounding: 5), position: 1)]
        )
    }

    @Test("The header and the entries load together")
    func load() async {
        let profiles = FakeProfiles(summary: summary, entries: [entry()])
        let store = ProfileStore(userID: userID, profiles: profiles)
        await store.load()
        #expect(store.header == .ready(summary))
        #expect(store.username == "jessw")
        #expect(store.entries.phase == .ready)
    }

    /// A blocked or deleted author is simply not there (contract, breaking change 2) — a page that
    /// crashes on a nil join is the bug that rule exists to prevent.
    @Test("A missing profile is a state, not a crash")
    func missingProfile() async {
        let profiles = FakeProfiles(summary: nil)
        let store = ProfileStore(userID: userID, profiles: profiles)
        await store.load()
        #expect(store.header == .unavailable)
        #expect(store.username == nil)
    }

    @Test("A header that fails does not take a loaded list with it")
    func headerFailsAlone() async {
        let profiles = FakeProfiles(summary: summary, entries: [entry()])
        profiles.headerError = URLError(.timedOut)
        let store = ProfileStore(userID: userID, profiles: profiles)
        await store.load()
        #expect(store.header == .unavailable)
        #expect(store.entries.entries.count == 1)
    }

    @Test("A profile with nothing public is an empty list, not a failure")
    func noEntries() async {
        let store = ProfileStore(userID: userID, profiles: FakeProfiles(summary: summary))
        await store.load()
        #expect(store.entries.phase == .empty)
        #expect(store.header == .ready(summary))
    }

    @Test("Blocking empties the page and says it went through")
    func block() async {
        let profiles = FakeProfiles(summary: summary, entries: [entry()])
        let store = ProfileStore(userID: userID, profiles: profiles)
        await store.load()
        let didBlock = await store.block()
        #expect(didBlock)
        #expect(store.isBlocked)
        #expect(store.entries.entries.isEmpty)
        #expect(profiles.blocked == [userID])
    }

    /// Popping the page and refetching the feed is the caller's job, and it must not happen when
    /// the block itself failed.
    @Test("A block that fails says so and changes nothing")
    func blockFails() async {
        let profiles = FakeProfiles(summary: summary, entries: [entry()])
        profiles.blockFails = true
        let store = ProfileStore(userID: userID, profiles: profiles)
        await store.load()
        let didBlock = await store.block()
        #expect(didBlock == false)
        #expect(store.isBlocked == false)
        #expect(store.entries.entries.count == 1)
    }

    @Test("Reporting sends the profile, and keeps the page where it is")
    func report() async {
        let profiles = FakeProfiles(summary: summary, entries: [entry()])
        let store = ProfileStore(userID: userID, profiles: profiles)
        await store.load()
        let reported = await store.report(reason: "spam")
        #expect(reported)
        #expect(profiles.reportedProfiles == [userID])
        #expect(store.entries.entries.count == 1)
    }
}
