import Foundation
import Supabase
import Synchronization
import Testing
@testable import AteKit

// MARK: - read-share's answer

@Suite("Share to Ate — read-share's answer")
struct ReadShareDecodingTests {
    @Test("decodes a full answer: a held place, the caption, the thumbnail")
    func full() throws {
        let json = Data("""
        {"ok":true,"source":"tiktok","url":"https://www.tiktok.com/@sydneyeats/video/7300000000000000000",
         "author":"@sydneyeats","caption":"The crab fried rice at Ho Jiak is unreal",
         "thumbnail_url":"https://p16-sign.tiktokcdn.com/obj/x.jpeg","dish":"Crab fried rice",
         "place_query":"Ho Jiak",
         "place":{"restaurant_id":"1B0C0B7E-2F7B-4B38-9A77-3A2F7B0C0B7E","google_place_id":null,
                  "name":"Ho Jiak","locality":"Haymarket, Sydney"}}
        """.utf8)
        let result = try ReadShareResult.decode(json)
        #expect(result.source == .tiktok)
        #expect(result.author == "@sydneyeats")
        #expect(result.dish == "Crab fried rice")
        #expect(result.placeQuery == "Ho Jiak")
        #expect(result.thumbnailURL == "https://p16-sign.tiktokcdn.com/obj/x.jpeg")
        let place = try #require(result.place)
        #expect(place.restaurantID == UUID(uuidString: "1b0c0b7e-2f7b-4b38-9a77-3a2f7b0c0b7e"))
        #expect(place.googlePlaceID == nil)
        #expect(place.locality == "Haymarket, Sydney")
        #expect(place.suggestion?.restaurantID == place.restaurantID)
    }

    @Test("an Instagram link with nothing read: every field null")
    func empty() throws {
        let json = Data("""
        {"ok":true,"source":"instagram","url":"https://www.instagram.com/reel/C1abc/","author":null,
         "caption":null,"thumbnail_url":null,"dish":null,"place_query":null,"place":null}
        """.utf8)
        let result = try ReadShareResult.decode(json)
        #expect(result.source == .instagram)
        #expect(result.dish == nil)
        #expect(result.place == nil)
        #expect(result.placeQuery == nil)
    }

    @Test("a Google-only place is a prediction to resolve, the place sheet's way")
    func googleOnly() throws {
        let json = Data("""
        {"ok":true,"source":"link","url":"https://www.broadsheet.com.au/melbourne/x","author":"",
         "caption":"  ","thumbnail_url":null,"dish":"Birria tacos","place_query":"La Tortilleria",
         "place":{"restaurant_id":null,"google_place_id":"ChIJ123","name":"La Tortilleria","locality":null}}
        """.utf8)
        let result = try ReadShareResult.decode(json)
        #expect(result.author == nil, "blank is absent")
        #expect(result.caption == nil)
        let suggestion = try #require(result.place?.suggestion)
        #expect(suggestion.selection == .googlePlace("ChIJ123"))
        #expect(suggestion.restaurantID == nil)
        #expect(suggestion.name == "La Tortilleria")
    }

    @Test("a source this build does not know is read off the link")
    func unknownSource() throws {
        let json = Data("""
        {"ok":true,"source":"youtube","url":"https://vm.tiktok.com/ZMabc/","place":null}
        """.utf8)
        #expect(try ReadShareResult.decode(json).source == .tiktok)
    }

    @Test("a status is a reason", arguments: [
        (401, ReadShareError.notAuthenticated, "unauthorized"),
        (422, .badURL, "bad_url"),
        (429, .rateLimited, "rate_limited"),
        (500, .failed(status: 500), "error")
    ])
    func statuses(status: Int, error: ReadShareError, reason: String) {
        #expect(ReadShareError(status: status) == error)
        #expect(error.reason == reason)
    }
}

// MARK: - The link the share sheet handed over

@Suite("Share to Ate — the shared link")
struct SharedLinkTests {
    @Test("the first https link in text, without the punctuation around it")
    func inText() {
        #expect(SharedLink.first(in: "Look at this! https://vm.tiktok.com/ZMabc/.")?.absoluteString
            == "https://vm.tiktok.com/ZMabc/")
        #expect(SharedLink.first(in: "http://insecure.example/x and https://www.instagram.com/reel/C1/")?
            .absoluteString == "https://www.instagram.com/reel/C1/")
        #expect(SharedLink.first(in: "no link here") == nil)
        #expect(SharedLink.first(in: nil) == nil)
    }

    @Test("a URL attachment wins over text, and only https counts")
    func attachmentsFirst() throws {
        let page = try #require(URL(string: "https://www.broadsheet.com.au/melbourne/x"))
        let file = try #require(URL(string: "file:///tmp/clip.mov"))
        #expect(SharedLink.first(urls: [file, page], texts: ["https://vm.tiktok.com/a"]) == page)
        #expect(SharedLink.first(urls: [file], texts: ["see https://vm.tiktok.com/a"])?.absoluteString
            == "https://vm.tiktok.com/a")
        #expect(SharedLink.first(urls: [], texts: []) == nil)
    }

    @Test("the words that came with the link, without the link alone")
    func words() throws {
        let link = try #require(URL(string: "https://vm.tiktok.com/a"))
        #expect(SharedLink.text(["https://vm.tiktok.com/a"], besides: link) == nil)
        #expect(SharedLink.text(["Crab fried rice at Ho Jiak ", "https://vm.tiktok.com/a"], besides: link)
            == "Crab fried rice at Ho Jiak")
    }

    @Test("the link card's lines", arguments: [
        SourceLineCase(
            source: .tiktok, url: "https://www.tiktok.com/@sydneyeats/video/1", author: "@sydneyeats",
            caption: "The crab fried rice at Ho Jiak is unreal",
            title: "@sydneyeats on TikTok", detail: "\u{201C}The crab fried rice at Ho Jiak is unreal\u{201D}"
        ),
        SourceLineCase(
            source: .instagram, url: "https://www.instagram.com/reel/C1abc/?igsh=x", author: "@melb.food",
            title: "@melb.food on Instagram", detail: "instagram.com/reel/\u{2026}"
        ),
        SourceLineCase(
            source: .instagram, url: "https://www.instagram.com/reel/C1abc/",
            title: "On Instagram", detail: "instagram.com/reel/\u{2026}"
        ),
        SourceLineCase(
            source: .link, url: "https://www.broadsheet.com.au/melbourne",
            title: "On broadsheet.com.au", detail: "broadsheet.com.au/melbourne"
        ),
        SourceLineCase(source: .link, url: "https://example.com", title: "On example.com", detail: "example.com")
    ])
    func lines(_ line: SourceLineCase) {
        #expect(OwnSaveSourceLine.title(source: line.source, url: line.url, author: line.author) == line.title)
        #expect(OwnSaveSourceLine.detail(url: line.url, caption: line.caption) == line.detail)
    }
}

/// One row of the link card's lines.
struct SourceLineCase: Sendable, CustomTestStringConvertible {
    var source: OwnSaveSource
    var url: String
    var author: String?
    var caption: String?
    var title: String
    var detail: String?

    var testDescription: String { title }
}

// MARK: - One sign-in, two targets

/// A keychain stand-in. `refuses` is a build signed without the app group.
private final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    let refuses: Bool

    init(_ items: [String: Data] = [:], refuses: Bool = false) {
        self.items = items
        self.refuses = refuses
    }

    struct Refused: Error {}

    func store(key: String, value: Data) throws {
        if refuses { throw Refused() }
        lock.withLock { items[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        if refuses { throw Refused() }
        return lock.withLock { items[key] }
    }

    func remove(key: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }

    var keys: [String] { lock.withLock { Array(items.keys) } }
}

@Suite("Share to Ate — the shared session")
struct SharedSessionStorageTests {
    private let key = "sb-cvoitgoaosofkougmarn-auth-token"
    private let session = Data("session".utf8)

    @Test("a tester signed in before this build is moved across on the first read, and stays signed in")
    func migrates() throws {
        let shared = MemoryStorage()
        let legacy = MemoryStorage([key: session])
        let storage = SharedSessionStorage(shared: shared, legacy: legacy)
        #expect(try storage.retrieve(key: key) == session)
        #expect(try shared.retrieve(key: key) == session)
        #expect(legacy.keys.isEmpty, "the old item goes once the shared one is written")
        #expect(try storage.retrieve(key: key) == session)
    }

    @Test("new sessions are written shared; sign-out clears both")
    func writesShared() throws {
        let shared = MemoryStorage()
        let legacy = MemoryStorage()
        let storage = SharedSessionStorage(shared: shared, legacy: legacy)
        try storage.store(key: key, value: session)
        #expect(try shared.retrieve(key: key) == session)
        #expect(legacy.keys.isEmpty)
        try storage.remove(key: key)
        #expect(try storage.retrieve(key: key) == nil)
    }

    @Test("without the app group nothing moves and the app works as it did")
    func refusedGroup() throws {
        let legacy = MemoryStorage([key: session])
        let storage = SharedSessionStorage(shared: MemoryStorage(refuses: true), legacy: legacy)
        #expect(try storage.retrieve(key: key) == session)
        #expect(legacy.keys == [key], "nothing is removed until it is safely elsewhere")
        let next = Data("refreshed".utf8)
        try storage.store(key: key, value: next)
        #expect(try storage.retrieve(key: key) == next)
    }

    @Test("signed out everywhere reads as nothing")
    func nothing() throws {
        let storage = SharedSessionStorage(shared: MemoryStorage(), legacy: MemoryStorage())
        #expect(try storage.retrieve(key: key) == nil)
    }
}

// MARK: - The inbox

@Suite("Share to Ate — the extension's notes to the app")
struct ShareInboxTests {
    private func freshInbox() -> (ShareInbox, String) {
        let suite = "ate.tests.share.\(UUID().uuidString)"
        return (ShareInbox(suiteName: suite), suite)
    }

    @Test("events are sent once, oldest first")
    func events() {
        let (inbox, suite) = freshInbox()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        inbox.post(ShareInEvents.signedOut())
        inbox.post(OwnSaveEvents.added(source: .tiktok, origin: .shareExtension))
        #expect(inbox.takeEvents() == [
            ShareInEvents.signedOut(), OwnSaveEvents.added(source: .tiktok, origin: .shareExtension)
        ])
        #expect(inbox.takeEvents().isEmpty)
    }

    @Test("the queue keeps the newest when it overflows")
    func overflow() {
        let (inbox, suite) = freshInbox()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for index in 0..<(ShareInbox.eventLimit + 5) {
            inbox.post(AnalyticsEvent(name: "e\(index)"))
        }
        let taken = inbox.takeEvents()
        #expect(taken.count == ShareInbox.eventLimit)
        #expect(taken.first?.name == "e5")
    }

    @Test("a save from the share sheet is noticed once")
    func changed() {
        let (inbox, suite) = freshInbox()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(inbox.takeOwnSavesChanged() == false)
        inbox.markOwnSavesChanged()
        #expect(inbox.takeOwnSavesChanged())
        #expect(inbox.takeOwnSavesChanged() == false)
    }
}

// MARK: - Events

@Suite("Share to Ate — events")
struct ShareInEventsTests {
    @Test("names and parameters are pinned")
    func names() {
        #expect(ShareInEvents.read(source: .tiktok, outcome: .suggested, dish: true, place: .google)
            == AnalyticsEvent(name: "share_read", parameters: [
                "source": "tiktok", "outcome": "suggested", "dish": "true", "place": "google"
            ]))
        let failed = ShareInEvents.read(
            source: .link, outcome: .failed, dish: false, place: .unmatched, reason: "rate_limited"
        )
        #expect(failed.parameters["reason"] == "rate_limited")
        #expect(failed.parameters["place"] == "none")
        #expect(ShareInEvents.signedOut().name == "share_signed_out")
        #expect(ShareInEvents.dismissed(source: .instagram, edited: true)
            == AnalyticsEvent(name: "share_dismissed", parameters: ["source": "instagram", "edited": "true"]))
        #expect(OwnSaveEvents.added(source: .instagram, origin: .shareExtension)
            == AnalyticsEvent(name: "own_save_added", parameters: ["source": "instagram", "origin": "share_extension"]))
    }
}

// MARK: - The card

private struct FakeReader: ReadSharing {
    let answer: Result<ReadShareResult, ReadShareError>

    func read(url: URL, text: String?) async throws -> ReadShareResult {
        try answer.get()
    }
}

/// Resolves a Google prediction to a fresh row, or refuses.
private struct FakePlaces: PlaceDirectory {
    var resolvesTo: UUID?

    func search(_ query: String) async throws -> [PlaceSuggestion] { [] }
    func recents(limit: Int) async throws -> [PlaceSuggestion] { [] }
    func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion] { [] }
    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef {
        guard let resolvesTo else { throw ReadShareError.failed(status: 502) }
        return PlaceRef(id: resolvesTo, name: suggestion.name)
    }
    func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef {
        PlaceRef(id: UUID(), name: name)
    }
    func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] { [] }
}

private let hoJiak = UUID()
private let tiktokLink = URL(string: "https://vm.tiktok.com/ZMabc/")!

private func tiktokRead(place: ReadSharePlace?) -> ReadShareResult {
    ReadShareResult(
        source: .tiktok, url: "https://www.tiktok.com/@sydneyeats/video/7300000000000000000",
        author: "@sydneyeats", caption: "The crab fried rice at Ho Jiak is unreal",
        thumbnailURL: "https://p16-sign.tiktokcdn.com/obj/x.jpeg", dish: "Crab fried rice",
        placeQuery: "Ho Jiak", place: place
    )
}

@MainActor
@Suite("Share to Ate — the card")
struct ShareCardModelTests {
    private func model(
        _ answer: Result<ReadShareResult, ReadShareError>,
        places: FakePlaces = FakePlaces(),
        saves: InMemoryOwnSaves = InMemoryOwnSaves(),
        signedIn: Bool = true,
        log: EventLog,
        onSaved: @escaping @MainActor () -> Void = {}
    ) -> ShareCardModel {
        ShareCardModel(
            reader: FakeReader(answer: answer), saves: saves, places: places, isSignedIn: signedIn,
            analytics: log.recorder, onSaved: onSaved
        )
    }

    @Test("a held place: both fields filled, Save live, and the save carries the post")
    func heldPlace() async throws {
        let log = EventLog()
        let saves = InMemoryOwnSaves()
        let noted = Mutex(false)
        let card = model(
            .success(tiktokRead(
                place: ReadSharePlace(restaurantID: hoJiak, name: "Ho Jiak", locality: "Haymarket, Sydney")
            )),
            saves: saves, log: log, onSaved: { noted.withLock { $0 = true } }
        )
        await card.start(link: tiktokLink, text: nil)
        #expect(card.phase == .ready)
        #expect(card.dish == "Crab fried rice")
        #expect(card.place == PlaceRef(id: hoJiak, name: "Ho Jiak"))
        #expect(card.placeDetail == "Haymarket, Sydney")
        #expect(card.sourceTitle == "@sydneyeats on TikTok")
        #expect(card.thumbnailURL?.host() == "p16-sign.tiktokcdn.com")
        #expect(card.canSave)
        #expect(log.first(named: "share_read")?.parameters["place"] == "local")
        #expect(log.first(named: "share_read")?.parameters["outcome"] == "suggested")

        #expect(await card.save())
        #expect(card.phase == .saved)
        #expect(noted.withLock { $0 })
        let saved = try #require(try await saves.ownSaves().first)
        #expect(saved.dishName == "Crab fried rice")
        #expect(saved.source == .tiktok)
        #expect(saved.sourceURL == "https://www.tiktok.com/@sydneyeats/video/7300000000000000000")
        #expect(saved.sourceAuthor == "@sydneyeats")
        #expect(saved.sourceCaption == "The crab fried rice at Ho Jiak is unreal")
        #expect(log.all.contains(OwnSaveEvents.added(source: .tiktok, origin: .shareExtension)))
    }

    @Test("a Google match is resolved into a real place before Save can use it")
    func googleResolved() async {
        let log = EventLog()
        let row = UUID()
        let card = model(
            .success(tiktokRead(place: ReadSharePlace(googlePlaceID: "ChIJ1", name: "Ho Jiak", locality: "Haymarket"))),
            places: FakePlaces(resolvesTo: row), log: log
        )
        await card.start(link: tiktokLink, text: nil)
        #expect(card.place?.id == row)
        #expect(card.isResolvingPlace == false)
        #expect(card.canSave)
        #expect(log.first(named: "share_read")?.parameters["place"] == "google")
    }

    @Test("a Google match that does not resolve leaves the place to find; the query seeds the sheet")
    func googleUnresolved() async {
        let card = model(
            .success(tiktokRead(place: ReadSharePlace(googlePlaceID: "ChIJ1", name: "Ho Jiak"))),
            places: FakePlaces(resolvesTo: nil), log: EventLog()
        )
        await card.start(link: tiktokLink, text: nil)
        #expect(card.place == nil)
        #expect(card.placeDetail == nil)
        #expect(card.placeQuery == "Ho Jiak")
        #expect(card.canSave == false, "a dish alone is not enough")
        card.pick(PlaceRef(id: hoJiak, name: "Ho Jiak"))
        #expect(card.canSave)
    }

    @Test("a failed read: empty fields, still saveable by hand")
    func failedRead() async {
        let log = EventLog()
        let card = model(.failure(.rateLimited), log: log)
        await card.start(link: tiktokLink, text: nil)
        #expect(card.phase == .ready)
        #expect(card.dish.isEmpty)
        #expect(card.place == nil)
        #expect(card.source == .tiktok, "the source still comes off the link")
        #expect(log.first(named: "share_read")?.parameters == [
            "source": "tiktok", "outcome": "failed", "dish": "false", "place": "none", "reason": "rate_limited"
        ])
        card.dish = "Crab fried rice"
        card.pick(PlaceRef(id: hoJiak, name: "Ho Jiak"))
        #expect(card.canSave)
        #expect(card.draft?.link == tiktokLink.absoluteString)
    }

    @Test("a place without an id is never saved")
    func placeWithoutID() async {
        let card = model(.failure(.badURL), log: EventLog())
        await card.start(link: tiktokLink, text: nil)
        card.dish = "Pho"
        card.pick(PlaceRef(id: nil, name: "Somewhere"))
        #expect(card.canSave == false)
    }

    @Test("signed out: the card says so and reads nothing")
    func signedOut() async {
        let log = EventLog()
        let card = model(.success(tiktokRead(place: nil)), signedIn: false, log: log)
        await card.start(link: tiktokLink, text: nil)
        #expect(card.phase == .signedOut)
        #expect(log.names == ["share_signed_out"])
    }

    @Test("a session the server refuses is signed out too")
    func refusedSession() async {
        let card = model(.failure(.notAuthenticated), log: EventLog())
        await card.start(link: tiktokLink, text: nil)
        #expect(card.phase == .signedOut)
    }

    @Test("a refused save says so and stays on the card")
    func refusedSave() async {
        let saves = InMemoryOwnSaves()
        await saves.failNextWrite()
        let card = model(
            .success(tiktokRead(place: ReadSharePlace(restaurantID: hoJiak, name: "Ho Jiak"))),
            saves: saves, log: EventLog()
        )
        await card.start(link: tiktokLink, text: nil)
        #expect(await card.save() == false)
        #expect(card.phase == .ready)
        #expect(card.failure == .addOwnSave)
    }

    @Test("closing without a save is counted, with whether anything was changed")
    func dismissed() async {
        let log = EventLog()
        let card = model(.success(tiktokRead(place: nil)), log: log)
        await card.start(link: tiktokLink, text: nil)
        card.dish = "Crab rice"
        card.dismissed()
        #expect(log.first(named: "share_dismissed")?.parameters == ["source": "tiktok", "edited": "true"])
    }
}
