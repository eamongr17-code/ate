import Foundation
import Testing
@testable import AteKit

/// Links into the app, and the inbox that holds one until it can open.
@MainActor
@Suite("Entry links")
struct EntryLinkTests {
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

    private static func situation(
        session: Bool = true, browsing: Bool = false, owesHandle: Bool = false, covered: Bool = false,
        shellUp: Bool = true
    ) -> EntryLinkInbox.Situation {
        EntryLinkInbox.Situation(
            hasSession: session, isBrowsing: browsing, owesHandle: owesHandle, isCovered: covered, isShellUp: shellUp
        )
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
        #expect(inbox.next(Self.situation(session: false, shellUp: false)) == .browse)
        #expect(inbox.pending == Self.id, "still held while the shell comes up")
        #expect(inbox.next(Self.situation(session: false, browsing: true, shellUp: false)) == .wait)
        #expect(inbox.next(Self.situation(session: false, browsing: true)) == .open(Self.id))
    }

    /// QA on #83: a push made in the turn the shell first appears was lost — the link waits for it.
    @Test func aLinkWaitsForTheShellToBeUp() {
        var inbox = EntryLinkInbox()
        inbox.receive(Self.id)
        #expect(inbox.next(Self.situation(shellUp: false)) == .wait)
        #expect(inbox.next(Self.situation()) == .open(Self.id))
    }

    @Test func aLinkWaitsForTheHandleStepAndForWhateverIsUp() {
        var inbox = EntryLinkInbox()
        inbox.receive(Self.id)
        #expect(inbox.next(Self.situation(owesHandle: true)) == .wait)
        #expect(inbox.next(Self.situation(covered: true)) == .wait, "under the composer, a sheet or the preview")
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

    @Test func linkEventsCarryIDsOnly() {
        let shared = LinkEvents.entryLinkShared(entryID: Self.id)
        #expect(shared.name == "entry_link_shared")
        #expect(shared.parameters == ["entry_id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"])
        #expect(LinkEvents.linkOpened(.entry(Self.id)).parameters["recognised"] == "true")
        #expect(LinkEvents.linkOpened(nil).parameters == ["recognised": "false"])
        #expect(LinkEvents.sheetOpened("place", ready: false).parameters == ["sheet": "place", "ready": "false"])
    }
}
