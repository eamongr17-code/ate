import Foundation
import Synchronization
import Testing
@testable import AteKit

@Suite("Nearby places")
@MainActor
struct NearbyPlacesTests {

    private final class Clock: Sendable {
        let at = Mutex(Date(timeIntervalSince1970: 0))
        func advance(_ seconds: TimeInterval) { at.withLock { $0 += seconds } }
        func now() -> Date { at.withLock { $0 } }
    }

    /// Something a main-actor closure can change.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Counts reads — each one may be a billed Places call.
    private final class CountingDirectory: PlaceDirectory {
        let reads = Mutex(0)
        let fails = Mutex(false)
        var readCount: Int { reads.withLock { $0 } }

        func search(_ query: String, near origin: SearchOrigin?) async throws -> [PlaceSuggestion] { [] }
        func recents(limit: Int) async throws -> [PlaceSuggestion] { [] }
        func nearby(latitude: Double, longitude: Double) async throws -> [PlaceSuggestion] {
            reads.withLock { $0 += 1 }
            if fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return [PlaceSuggestion(restaurantID: UUID(), name: "Tipo 00", subtitle: nil, distanceMeters: 20)]
        }
        func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceRef {
            PlaceRef(id: suggestion.restaurantID, name: suggestion.name)
        }
        func add(name: String, suburb: String?, street: String?) async throws -> PlaceRef {
            PlaceRef(id: UUID(), name: name)
        }
        func dishes(atPlace placeID: UUID, limit: Int) async throws -> [PlaceDish] { [] }
    }

    private static let cbd = SearchOrigin(latitude: -37.8118, longitude: 144.9629)
    /// About 1 km north.
    private static let carlton = SearchOrigin(latitude: -37.8018, longitude: 144.9629)

    @Test("The + warms the read, and the sheet opens on it without a second one")
    func warmedReadServesTheSheet() async {
        let directory = CountingDirectory()
        let nearby = NearbyPlaces(directory: directory, locate: { _ in Self.cbd })
        nearby.warm()
        let answer = await nearby.answer()
        #expect(answer?.rooms.map(\.name) == ["Tipo 00"])
        #expect(answer?.origin == Self.cbd)
        #expect(directory.readCount == 1)
    }

    @Test("Warming never raises the permission alert; the sheet still asks")
    func warmDoesNotAsk() async {
        let directory = CountingDirectory()
        let asks = Box<[Bool]>([])
        let nearby = NearbyPlaces(directory: directory, locate: { mayAsk in
            asks.value.append(mayAsk)
            return mayAsk ? Self.cbd : nil
        })
        nearby.warm()
        let answer = await nearby.answer()
        #expect(asks.value == [false, true])
        #expect(answer?.rooms.isEmpty == false)
        #expect(directory.readCount == 1)
    }

    @Test("No permission is no answer and no read")
    func noPermission() async {
        let directory = CountingDirectory()
        let nearby = NearbyPlaces(directory: directory, locate: { _ in nil })
        nearby.warm()
        #expect(await nearby.answer() == nil)
        #expect(directory.readCount == 0)
    }

    @Test("Many + taps in a few minutes from one spot cost one read")
    func reusedWhileFresh() async {
        let directory = CountingDirectory()
        let clock = Clock()
        let nearby = NearbyPlaces(directory: directory, locate: { _ in Self.cbd }, now: { clock.now() })
        for _ in 0..<3 {
            nearby.warm()
            _ = await nearby.answer()
            clock.advance(60)
        }
        #expect(directory.readCount == 1)
    }

    @Test("A stale read is read again")
    func staleRereads() async {
        let directory = CountingDirectory()
        let clock = Clock()
        let nearby = NearbyPlaces(directory: directory, locate: { _ in Self.cbd }, now: { clock.now() })
        _ = await nearby.answer()
        clock.advance(NearbyPlaces.freshFor + 1)
        _ = await nearby.answer()
        #expect(directory.readCount == 2)
    }

    @Test("Moving away is read again")
    func movedRereads() async {
        let directory = CountingDirectory()
        let spot = Box(Self.cbd)
        let nearby = NearbyPlaces(directory: directory, locate: { _ in spot.value })
        _ = await nearby.answer()
        spot.value = Self.carlton
        let answer = await nearby.answer()
        #expect(answer?.origin == Self.carlton)
        #expect(directory.readCount == 2)
    }

    @Test("A failed read keeps the origin and is not kept")
    func failureNotHeld() async {
        let directory = CountingDirectory()
        directory.fails.withLock { $0 = true }
        let nearby = NearbyPlaces(directory: directory, locate: { _ in Self.cbd })
        let failed = await nearby.answer()
        #expect(failed == NearbyPlaces.Answer(origin: Self.cbd, rooms: []))
        directory.fails.withLock { $0 = false }
        let next = await nearby.answer()
        #expect(next?.rooms.isEmpty == false)
        #expect(directory.readCount == 2)
    }

    @Test("Distance is close enough to tell a block from a suburb")
    func distance() {
        #expect(NearbyPlaces.meters(from: Self.cbd, to: Self.cbd) == 0)
        let km = NearbyPlaces.meters(from: Self.cbd, to: Self.carlton)
        #expect(km > 1_000 && km < 1_250)
    }
}
