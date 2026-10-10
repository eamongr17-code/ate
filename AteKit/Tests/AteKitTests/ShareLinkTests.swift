import Foundation
import Testing
@testable import AteKit

/// List links, and the share loop's events.
@Suite("Share links and events")
struct ShareLinkTests {
    private static let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    @Test func aListLinkIsTheAppsOwnSchemeAndReadsBack() {
        #expect(AteLinks.list(Self.id).absoluteString == "ate://list/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(AteLinks.parse(AteLinks.list(Self.id)) == .list(Self.id))
        #expect(AteLinks.parse(URL(string: "ATE://List/3F2504E0-4F89-11D3-9A0C-0305E82C3301/")!) == .list(Self.id))
        #expect(AteLinks.parse(URL(string: "ate://list/not-a-uuid")!) == nil)
        #expect(AteLinks.parse(URL(string: "ate://lists/\(Self.id)")!) == nil)
    }

    @Test func aDomainBaseBuildsAndReadsListLinks() {
        let base = URL(string: "https://ate.example/")!
        let link = AteLinks.list(Self.id, base: base)
        #expect(link.absoluteString == "https://ate.example/list/3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(AteLinks.parse(link, base: base) == .list(Self.id))
        #expect(AteLinks.parse(URL(string: "ate://list/\(Self.id)")!, base: base) == .list(Self.id))
    }

    @Test func aListLinkOpeningIsCountedByKind() {
        let event = LinkEvents.linkOpened(.list(Self.id))
        #expect(event.name == "link_opened")
        #expect(event.parameters["kind"] == "list")
        #expect(event.parameters["list_id"] == Self.id.uuidString.lowercased())
        #expect(event.parameters["recognised"] == "true")
    }

    @Test func receiptSharedKeepsItsNameAndCarriesWhereItWent() {
        let event = ShareEvents.receiptShared(
            entryID: Self.id, source: .entry, destination: .instagramStories, sticker: .photo
        )
        #expect(event.name == "receipt_shared")
        #expect(event.parameters["entry_id"] == Self.id.uuidString.lowercased())
        #expect(event.parameters["source"] == "entry")
        #expect(event.parameters["destination"] == "instagram_stories")
        #expect(event.parameters["sticker"] == "photo")
        #expect(ShareDestination.allCases.map(\.rawValue).sorted()
            == ["clipboard", "instagram_stories", "link", "messages", "saved", "system"])
        #expect(ShareSticker.allCases.map(\.rawValue).sorted() == ["photo", "slip"])
    }

    @Test func listSharedCarriesTheListAndItsSize() {
        let event = ShareEvents.listShared(listID: Self.id, destination: .link, count: 12)
        #expect(event.name == "list_shared")
        #expect(event.parameters["list_id"] == Self.id.uuidString.lowercased())
        #expect(event.parameters["destination"] == "link")
        #expect(event.parameters["count"] == "12")
        #expect(ShareEvents.listShared(listID: Self.id, destination: .link, count: -1).parameters["count"] == "0")
    }
}
