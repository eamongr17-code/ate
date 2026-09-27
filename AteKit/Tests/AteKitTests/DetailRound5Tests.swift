import Foundation
import Testing
@testable import AteKit

/// Round 5, detail + share: links into the app, sheets that rise only once their rows are in hand,
/// and the events both ship with.
@MainActor
@Suite("Detail round 5")
struct DetailRound5Tests {

    // MARK: - Links

    private static let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test func anEntryLinkIsTheAppsOwnSchemeAndALowercasedID() {
        #expect(AteLinks.entry(Self.id).absoluteString == "ate://entry/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    }

    @Test func anEntryLinkReadsBackToItsEntry() {
        #expect(AteLinks.parse(AteLinks.entry(Self.id)) == .entry(Self.id))
        #expect(AteLinks.parse(URL(string: "ate://entry/3F2504E0-4F89-11D3-9A0C-0305E82C3301")!) == .entry(Self.id))
        #expect(AteLinks.parse(URL(string: "ATE://Entry/3f2504e0-4f89-11d3-9a0c-0305e82c3301/")!) == .entry(Self.id))
    }

    @Test func whatIsNotOneOfOursOpensNothing() {
        for text in [
            "ate://entry/not-a-uuid",
            "ate://entry",
            "ate://profile/3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            "ate://entry/3f2504e0-4f89-11d3-9a0c-0305e82c3301/extra",
            "https://ate.app/entry/3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            "mailto:someone@example.com"
        ] {
            #expect(AteLinks.parse(URL(string: text)!) == nil, "\(text)")
        }
    }

    /// The day a domain replaces the scheme, links are built from it and read against it — and a
    /// link already sent on the old scheme still opens.
    @Test func aDomainBaseBuildsAndReadsItsOwnLinks() {
        let base = URL(string: "https://ate.example/")!
        let link = AteLinks.entry(Self.id, base: base)
        #expect(link.absoluteString == "https://ate.example/entry/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(AteLinks.parse(link, base: base) == .entry(Self.id))
        #expect(AteLinks.parse(URL(string: "https://www.ate.example/entry/\(Self.id)")!, base: base) == .entry(Self.id))
        #expect(AteLinks.parse(URL(string: "ate://entry/\(Self.id)")!, base: base) == .entry(Self.id))
        #expect(AteLinks.parse(URL(string: "https://elsewhere.example/entry/\(Self.id)")!, base: base) == nil)
    }

    // MARK: - Sheets rise once their rows are in hand

    @Test func aReadThatAnswersInTimeIsWaitedFor() async {
        var landed = false
        let ready = await SheetReadiness.wait(atMost: .seconds(5)) {
            try? await Task.sleep(for: .milliseconds(20))
            landed = true
        }
        #expect(ready)
        #expect(landed)
    }

    @Test func aSlowReadIsNotWaitedForButIsNotCutShort() async throws {
        let box = Box()
        let ready = await SheetReadiness.wait(atMost: .milliseconds(30)) {
            try? await Task.sleep(for: .milliseconds(250))
            box.landed = true
        }
        #expect(ready == false)
        #expect(box.landed == false)
        try await Task.sleep(for: .milliseconds(600))
        #expect(box.landed, "the read keeps going and lands in the sheet that is already up")
    }

    @MainActor
    private final class Box {
        var landed = false
    }

    @Test func aSheetThatWentUpEarlyHoldsItsReservedHeight() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.head = 50
        fit.body = 40 // still rows
        fit.reserve(800)
        #expect(fit.tallest == 800)
        fit.body = 300 // the rows land, shorter than the reserve
        #expect(fit.tallest == 800, "it does not move")
    }

    // MARK: - Read ahead

    @Test func theFeedsAreasAreReadAheadOnce() async {
        let reader = CountingAreas()
        let model = FeedAreaModel(reader: reader, store: InMemoryKeyValueStore(), owner: { nil })
        #expect(model.hasLoadedAreas == false)
        await model.loadAreasIfNeeded()
        await model.loadAreasIfNeeded()
        #expect(model.hasLoadedAreas)
        #expect(model.areas.map(\.area) == ["CBD", "Fitzroy"])
        #expect(await reader.calls == 1)
    }

    @Test func aFailedReadStillAnswersTheSheetAndIsAskedAgain() async {
        let reader = CountingAreas(failing: true)
        let model = FeedAreaModel(reader: reader, store: InMemoryKeyValueStore(), owner: { nil })
        await model.loadAreasIfNeeded()
        #expect(model.hasAnsweredAreas, "no still rows left standing in an open sheet")
        #expect(model.hasLoadedAreas == false)
        await model.loadAreasIfNeeded()
        #expect(await reader.calls == 2, "the next open asks again")
    }

    // MARK: - A link waits until it can open

    private static func situation(
        session: Bool = true, browsing: Bool = false, owesHandle: Bool = false, covered: Bool = false
    ) -> EntryLinkInbox.Situation {
        EntryLinkInbox.Situation(hasSession: session, isBrowsing: browsing, owesHandle: owesHandle, isCovered: covered)
    }

    @Test func aLinkOnTheShellOpensAtOnce() {
        var inbox = EntryLinkInbox()
        inbox.receive(Self.id)
        #expect(inbox.next(Self.situation()) == .open(Self.id))
        #expect(inbox.next(Self.situation()) == .wait, "once")
    }

    @Test func aLinkOnWelcomeBrowsesThenOpens() {
        var inbox = EntryLinkInbox()
        inbox.receive(Self.id)
        #expect(inbox.next(Self.situation(session: false)) == .browseAndOpen(Self.id))
        inbox.receive(Self.id)
        #expect(inbox.next(Self.situation(session: false, browsing: true)) == .open(Self.id))
    }

    @Test func aLinkWaitsForTheHandleStepAndForWhateverIsUp() {
        var inbox = EntryLinkInbox()
        inbox.receive(Self.id)
        #expect(inbox.next(Self.situation(owesHandle: true)) == .wait)
        #expect(inbox.next(Self.situation(covered: true)) == .wait, "under the composer or the sign-in ask")
        #expect(inbox.pending == Self.id, "still held")
        #expect(inbox.next(Self.situation()) == .open(Self.id))
    }

    @Test func theNewestLinkWins() {
        var inbox = EntryLinkInbox()
        let other = UUID()
        inbox.receive(Self.id)
        inbox.receive(other)
        #expect(inbox.next(Self.situation()) == .open(other))
    }

    @Test func aSheetWaitingOnAReadAheadWaitsForItToLand() async {
        let reader = SlowAreas()
        let model = FeedAreaModel(reader: reader, store: InMemoryKeyValueStore(), owner: { nil })
        let ahead = Task { await model.loadAreasIfNeeded() }
        await Task.yield()
        await model.loadAreasIfNeeded() // the sheet's prepare, while the read-ahead is in flight
        #expect(model.hasLoadedAreas, "joined the read, did not skip past it")
        await ahead.value
        #expect(await reader.calls == 1)
    }

    // MARK: - Events

    @Test func linkEventsCarryIDsOnly() {
        let shared = LinkEvents.entryLinkShared(entryID: Self.id)
        #expect(shared.name == "entry_link_shared")
        #expect(shared.parameters == ["entry_id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"])
        #expect(LinkEvents.linkOpened(.entry(Self.id)).parameters["recognised"] == "true")
        #expect(LinkEvents.linkOpened(nil).parameters == ["recognised": "false"])
        #expect(LinkEvents.sheetOpened("place", ready: false).parameters == ["sheet": "place", "ready": "false"])
    }
}

/// One area, slowly.
private actor SlowAreas: EntryFeedReading {
    var calls = 0

    func feedPage(
        after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
    ) async throws -> Page<EntryCard> {
        Page(items: [], nextCursor: nil)
    }

    func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        calls += 1
        try? await Task.sleep(for: .milliseconds(80))
        return [FeedArea(area: "CBD", count: 9)]
    }
}

/// Two areas, and how many times they were asked for.
private actor CountingAreas: EntryFeedReading {
    var calls = 0
    let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    func feedPage(
        after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
    ) async throws -> Page<EntryCard> {
        Page(items: [], nextCursor: nil)
    }

    func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] {
        calls += 1
        if failing { throw URLError(.notConnectedToInternet) }
        return [FeedArea(area: "CBD", count: 9), FeedArea(area: "Fitzroy", count: 4)]
    }
}
