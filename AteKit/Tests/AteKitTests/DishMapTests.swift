import Foundation
import Synchronization
import Testing
@testable import AteKit

@Suite("Dish map")
@MainActor
struct DishMapTests {

    // MARK: - Which places get photos

    private func candidate(_ number: Int, _ across: Double, _ down: Double, _ score: Double?, dishes: Int = 1)
        -> DishMapLayout.Candidate {
        DishMapLayout.Candidate(id: id(number), across: across, down: down, score: score, dishCount: dishes)
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    @Test("best-rated places take photos while they fit; the rest are dots")
    func photosWhileTheyFit() {
        let packed = [
            candidate(1, 100, 100, 4.2),
            candidate(2, 120, 110, 4.9),   // best, and on top of 1
            candidate(3, 300, 100, 3.5),   // far from both
            candidate(4, 110, 130, nil)    // unscored, on top of 2
        ]
        #expect(DishMapLayout.photoPins(packed) == [id(2), id(3)])
    }

    @Test("zooming in spreads the same places, so more of them get photos")
    func zoomingInMakesRoom() {
        let zoomedOut = (0..<10).map { candidate($0, Double($0) * 20, 0, 4) }
        let zoomedIn = (0..<10).map { candidate($0, Double($0) * 80, 0, 4) }
        #expect(DishMapLayout.photoPins(zoomedOut).count == 3)
        #expect(DishMapLayout.photoPins(zoomedIn).count == 10)
    }

    @Test("a tapped dot always grows into its photos, even beside a better place")
    func selectedAlwaysShows() {
        let pair = [candidate(1, 100, 100, 4.9), candidate(2, 110, 100, 3.0)]
        #expect(DishMapLayout.photoPins(pair) == [id(1)])
        #expect(DishMapLayout.photoPins(pair, selected: id(2)) == [id(2)])
    }

    @Test("never more than the cap; equal scores go to the place with more dishes, then the id")
    func capAndTies() {
        let spread = (0..<30).map { candidate($0, Double($0) * 100, 0, 4) }
        #expect(DishMapLayout.photoPins(spread).count == DishMapLayout.maximumPhotos)
        let tie = [candidate(1, 0, 0, 4, dishes: 1), candidate(2, 10, 0, 4, dishes: 3)]
        #expect(DishMapLayout.photoPins(tie) == [id(2)])
        #expect(DishMapLayout.photoPins(tie.reversed()) == [id(2)], "the order handed in does not matter")
    }

    // MARK: - Framing, title, distance

    @Test("the opening frame holds the phone and every place, with room at the edges")
    func framing() throws {
        let points = [
            SearchOrigin(latitude: -37.80, longitude: 144.97), SearchOrigin(latitude: -37.85, longitude: 145.00)
        ]
        let box = try #require(MapBox.fitting(points))
        for point in points {
            #expect(box.contains(latitude: point.latitude, longitude: point.longitude))
        }
        #expect(box.latitudeDelta > 0.05)
        let single = try #require(MapBox.fitting([points[0]]))
        #expect(single.latitudeDelta >= 0.01, "one point still gets a street's worth of map")
        #expect(MapBox.fitting([]) == nil)
    }

    @Test("Dishes near you while you are on the map; the suburb once it is dragged away")
    func title() {
        let fitzroy = MapBox(
            centerLatitude: -37.80, centerLongitude: 144.98, latitudeDelta: 0.02, longitudeDelta: 0.02
        )
        let phone = SearchOrigin(latitude: -37.80, longitude: 144.98)
        let elsewhere = SearchOrigin(latitude: -37.90, longitude: 145.10)
        #expect(DishMapTitle.resolve(box: fitzroy, phone: phone, area: "Fitzroy") == .nearYou)
        #expect(DishMapTitle.resolve(box: fitzroy, phone: elsewhere, area: "Fitzroy") == .inArea("Fitzroy"))
        #expect(DishMapTitle.resolve(box: fitzroy, phone: elsewhere, area: nil) == .nearYou)
        #expect(DishMapTitle.resolve(box: fitzroy, phone: nil, area: "Fitzroy").text == "Dishes in Fitzroy")
        #expect(DishMapTitle.nearYou.text == "Dishes near you")
    }

    @Test("distances read the way the sheet prints them")
    func distances() {
        #expect(MapDistance.text(meters: 4) == "10 m")
        #expect(MapDistance.text(meters: 348) == "350 m")
        #expect(MapDistance.text(meters: 1260) == "1.3 km")
        #expect(MapDistance.text(meters: 12_400) == "12 km")
    }

    // MARK: - The wire

    @Test("map_places and map_dishes rows decode, unscored ones included")
    func decoding() throws {
        let places = Data("""
        [{"restaurant_id":"00000000-0000-4000-8000-0000000000f1","name":"Tipo 00","locality":"Melbourne",
          "latitude":-37.8136,"longitude":144.9631,"distance_m":1480,"dish_count":2,
          "top_dish_id":"00000000-0000-4000-8000-000000000001","top_dish_name":"Tiramisu","top_score":5.0,
          "top_cover_url":"https://x/a.jpg","second_cover_url":null},
         {"restaurant_id":"00000000-0000-4000-8000-0000000000f2","name":"Marion","locality":null,
          "latitude":-37.806,"longitude":144.982,"distance_m":null,"dish_count":1,
          "top_dish_id":"00000000-0000-4000-8000-000000000002","top_dish_name":"Anchovies","top_score":null,
          "top_cover_url":null,"second_cover_url":null}]
        """.utf8)
        let rows = try JSONDecoder().decode([MapPlace].self, from: places)
        #expect(rows.map(\.topScore) == [5.0, nil])
        #expect(rows[0].distanceMeters == 1480 && rows[1].distanceMeters == nil)
        #expect(rows[0].origin == SearchOrigin(latitude: -37.8136, longitude: 144.9631))

        let dishes = Data("""
        [{"dish_id":"00000000-0000-4000-8000-000000000001","dish_name":"Tiramisu","score":5.0,"review_count":1,
          "cover_url":null,"restaurant_id":"00000000-0000-4000-8000-0000000000f1","place_name":"Tipo 00",
          "locality":"Melbourne","distance_m":1480}]
        """.utf8)
        let dish = try #require(try JSONDecoder().decode([MapDish].self, from: dishes).first)
        #expect(dish.cursor == MapDishCursor(score: 5, reviewCount: 1, dishID: dish.dishID))
    }

    // MARK: - The store

    private final class Reads: DishMapReading {
        let nearestPlaces: [MapPlace]
        let gate = Mutex<[CheckedContinuation<Void, Never>]>([])
        let holdNextShow = Mutex(false)
        let boxes = Mutex<[MapBox]>([])

        init(nearest: [MapPlace]) { self.nearestPlaces = nearest }

        func places(in box: MapBox, origin: SearchOrigin?, limit: Int) async throws -> [MapPlace] {
            boxes.withLock { $0.append(box) }
            if holdNextShow.withLock({ held in defer { held = false }; return held }) {
                await withCheckedContinuation { continuation in gate.withLock { $0.append(continuation) } }
            }
            return [MapPlace(restaurantID: UUID(), name: "Seen at \(box.centerLatitude)",
                             latitude: box.centerLatitude, longitude: box.centerLongitude)]
        }

        func nearest(to origin: SearchOrigin?, limit: Int) async throws -> [MapPlace] { nearestPlaces }

        func dishes(in box: MapBox, origin: SearchOrigin?, after cursor: MapDishCursor?, pageSize: Int)
            async throws -> MapDishPage {
            MapDishPage(items: [], requestedLimit: pageSize)
        }

        func release() { gate.withLock { $0.forEach { $0.resume() }; $0.removeAll() } }
    }

    /// A place's menu: one dish, named for the place.
    private struct Menus: PlacePageReading {
        func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
            throw AteAPIError.notFound(table: "restaurants", id: restaurantID)
        }
        func placeDishes(restaurantID: UUID, after cursor: MenuDishCursor?, pageSize: Int) async throws
            -> MenuDishPage {
            MenuDishPage(items: [MenuDish(dishID: restaurantID, name: "Dish")], requestedLimit: pageSize)
        }
        func entriesAtPlace(
            restaurantID: UUID, scope: PlaceEntryScope, after cursor: PageCursor?, pageSize: Int
        ) async throws -> Page<EntryCard> {
            Page(items: [], nextCursor: nil)
        }
    }

    private let fitzroy = SearchOrigin(latitude: -37.80, longitude: 144.98)
    private let geelong = MapPlace(restaurantID: UUID(), name: "Tipo Far", latitude: -38.149, longitude: 144.36)

    @Test("opens framed on the phone and the nearest places, however far, and says so")
    func opensFramed() async throws {
        let events = Mutex<[String]>([])
        let store = DishMapStore(reads: Reads(nearest: [geelong]), menus: Menus(), locate: { _ in self.fitzroy },
                                 analytics: { event in events.withLock { $0.append(event.name) } })
        await store.open()
        let frame = try #require(store.frame)
        #expect(frame.contains(latitude: fitzroy.latitude, longitude: fitzroy.longitude))
        #expect(frame.contains(latitude: geelong.latitude, longitude: geelong.longitude))
        #expect(store.places == [geelong])
        #expect(events.withLock { $0 } == ["map_opened"])
    }

    @Test("location off still opens on the record's busiest place")
    func opensWithoutLocation() async throws {
        let store = DishMapStore(reads: Reads(nearest: [geelong]), menus: Menus(), locate: { _ in nil })
        await store.open()
        let frame = try #require(store.frame)
        #expect(frame.contains(latitude: geelong.latitude, longitude: geelong.longitude))
        #expect(store.phone == nil)
    }

    @Test("a read that lands after a newer one was asked for is dropped")
    func staleReadDropped() async throws {
        let reads = Reads(nearest: [])
        let store = DishMapStore(reads: reads, menus: Menus(), locate: { _ in nil })
        let old = MapBox(centerLatitude: -37.80, centerLongitude: 144.98, latitudeDelta: 0.01, longitudeDelta: 0.01)
        let new = MapBox(centerLatitude: -37.70, centerLongitude: 144.98, latitudeDelta: 0.01, longitudeDelta: 0.01)
        reads.holdNextShow.withLock { $0 = true }
        let slow = Task { await store.show(old) }
        while reads.boxes.withLock({ $0.count }) < 1 { await Task.yield() }
        await store.show(new)
        reads.release()
        await slow.value
        #expect(store.places.map(\.name) == ["Seen at \(new.centerLatitude)"])
        #expect(store.box == new)
        #expect(store.phase == .ready)
    }

    @Test("tapping a place selects it with its dishes, tapping it again lets it go")
    func selecting() async {
        let store = DishMapStore(reads: Reads(nearest: []), menus: Menus(), locate: { _ in nil })
        await store.select(geelong)
        #expect(store.selected == geelong)
        #expect(store.selectedMenu.map(\.dishID) == [geelong.restaurantID])
        await store.select(geelong)
        #expect(store.selected == nil)
        #expect(store.selectedMenu.isEmpty)
    }
}
