import Foundation
import Testing
@testable import AteKit

/// The nearby-place chips on a photo sitting: three at most, one lookup at a time in the order the
/// sittings appeared, cached for the session, and never a second ask within 75 m of a first.
@Suite("Photo place chips")
@MainActor
struct PhotoPlaceChipsTests {
    /// A fake `places-search?op=nearby`: records each ask and how many ran at once.
    actor FakeNearby {
        private(set) var asked: [PhotoCoordinate] = []
        private(set) var inFlight = 0
        private(set) var mostAtOnce = 0
        var fails = false

        func setFails(_ value: Bool) { fails = value }

        func nearby(_ coordinate: PhotoCoordinate) async throws -> [PlaceSuggestion] {
            asked.append(coordinate)
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
            try? await Task.sleep(nanoseconds: 2_000_000)
            inFlight -= 1
            if fails { throw URLError(.notConnectedToInternet) }
            return (1...5).map { PlaceSuggestion(restaurantID: UUID(), name: "Place \($0)") }
        }
    }

    private let tipo = PhotoCoordinate(latitude: -37.8125, longitude: 144.9650)
    /// About 45 m east of Tipo 00.
    private let nextDoor = PhotoCoordinate(latitude: -37.8125, longitude: 144.9655)
    /// Lygon St, about 1.9 km north.
    private let lygon = PhotoCoordinate(latitude: -37.7955, longitude: 144.9665)

    private func planner(_ fake: FakeNearby) -> PhotoPlaceChips {
        PhotoPlaceChips { try await fake.nearby($0) }
    }

    @Test("A sitting shows at most three chips")
    func capsAtThree() async {
        let fake = FakeNearby()
        let chips = planner(fake)
        chips.appeared("a", at: tipo)
        await chips.drain()
        #expect(chips.chips(for: "a").count == 3)
        #expect(chips.chips(for: "a").map(\.name) == ["Place 1", "Place 2", "Place 3"])
    }

    @Test("No location: no ask, no chips")
    func noLocationNoChips() async {
        let fake = FakeNearby()
        let chips = planner(fake)
        chips.appeared("a", at: nil)
        await chips.drain()
        #expect(chips.chips(for: "a").isEmpty)
        #expect(await fake.asked.isEmpty)
    }

    @Test("A sitting within 75 m of one already asked reuses its answer")
    func dedupesByDistance() async {
        let fake = FakeNearby()
        let chips = planner(fake)
        #expect(tipo.distance(to: nextDoor) < PhotoPlaceChips.sameSpot)
        chips.appeared("a", at: tipo)
        chips.appeared("b", at: nextDoor)
        chips.appeared("c", at: lygon)
        await chips.drain()
        #expect(await fake.asked.count == 2)
        #expect(chips.chips(for: "b") == chips.chips(for: "a"))
        #expect(chips.chips(for: "c").count == 3)
    }

    @Test("Answers are cached for the session")
    func caches() async {
        let fake = FakeNearby()
        let chips = planner(fake)
        chips.appeared("a", at: tipo)
        await chips.drain()
        chips.appeared("a", at: tipo)
        chips.appeared("later", at: tipo)
        await chips.drain()
        #expect(await fake.asked.count == 1)
        #expect(chips.chips(for: "later").count == 3)
    }

    @Test("One lookup at a time, in the order the sittings appeared")
    func serialInOrder() async {
        let fake = FakeNearby()
        let chips = planner(fake)
        chips.appeared("north", at: lygon)
        chips.appeared("city", at: tipo)
        async let first: Void = chips.drain()
        async let second: Void = chips.drain()
        _ = await (first, second)
        #expect(await fake.mostAtOnce == 1)
        #expect(await fake.asked == [lygon.rounded, tipo.rounded])
    }

    @Test("A sitting that left the screen before its turn is not asked about")
    func offScreenSkipped() async {
        let fake = FakeNearby()
        let chips = planner(fake)
        chips.appeared("a", at: tipo)
        chips.appeared("b", at: lygon)
        chips.disappeared("b")
        await chips.drain()
        #expect(await fake.asked == [tipo.rounded])
        #expect(chips.chips(for: "b").isEmpty)
    }

    @Test("A failure is silent and is not cached")
    func failureSilent() async {
        let fake = FakeNearby()
        await fake.setFails(true)
        let chips = planner(fake)
        chips.appeared("a", at: tipo)
        await chips.drain()
        #expect(chips.chips(for: "a").isEmpty)
        await fake.setFails(false)
        chips.appeared("a", at: tipo)
        await chips.drain()
        #expect(chips.chips(for: "a").count == 3)
    }

    @Test("The bell's number is tags plus photo sittings, never below zero")
    func inboxCount() {
        #expect(NotificationsInbox.count(unreadTags: 2, photoSuggestions: 3) == 5)
        #expect(NotificationsInbox.count(unreadTags: 0, photoSuggestions: 0) == 0)
        #expect(NotificationsInbox.count(unreadTags: -1, photoSuggestions: 2) == 2)
    }

    @Test("A sitting's location is its first photo that has one")
    func clusterCoordinate() {
        let now = Date()
        let cluster = PhotoSuggestionCluster(items: [
            PhotoSuggestionItem(id: "a", createdAt: now),
            PhotoSuggestionItem(id: "b", createdAt: now, coordinate: tipo)
        ])
        #expect(cluster.coordinate == tipo)
        #expect(PhotoSuggestionCluster(items: [PhotoSuggestionItem(id: "c", createdAt: now)]).coordinate == nil)
    }

    @Test("The two new events carry their counts")
    func events() {
        let opened = NotificationEvents.notificationsSectionOpened(tags: 2, photos: 3)
        #expect(opened.name == "notifications_section_opened")
        #expect(opened.parameters == ["tags": "2", "photos": "3"])
        let tapped = NotificationEvents.photoPlaceChipTapped(rank: 1)
        #expect(tapped.name == "photo_place_chip_tapped")
        #expect(tapped.parameters == ["rank": "1"])
    }
}
