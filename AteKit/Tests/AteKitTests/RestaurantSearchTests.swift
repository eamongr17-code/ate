import Foundation
import Testing

@testable import AteKit

@Suite("Restaurant search — wire contract + rows")
struct RestaurantSearchTests {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - autocomplete (manual-search-blend-contract §2)

    @Test("the blended results[] decodes both kinds and keeps server order")
    func blendDecodes() throws {
        let response = try decode(PlacesAutocompleteResponse.self, """
        {
          "stub": false,
          "predictions": [{"google_place_id": "ChIJ1", "name": "Chin Chin"}],
          "results": [
            {"kind": "manual", "id": "8E7A0A5C-0000-4000-8000-000000000001", "name": "Marg's Diner",
             "city": "Fitzroy", "cuisine": null, "match_score": 0.85},
            {"kind": "place", "google_place_id": "ChIJ1", "name": "Chin Chin",
             "secondary": "Flinders Ln, Melbourne", "distance_meters": 540}
          ]
        }
        """)

        #expect(response.stub == false)
        #expect(response.results.count == 2)
        // Server ranking: the strong manual match leads. The client must not re-sort.
        #expect(response.results.map(\.kind) == ["manual", "place"])
        #expect(response.results.map(\.name) == ["Marg's Diner", "Chin Chin"])
    }

    @Test("an unknown result kind costs one row, not the whole search")
    func lossyResults() throws {
        let response = try decode(PlacesAutocompleteResponse.self, """
        {"stub": false, "results": [
          {"kind": "someday", "id": "x"},
          {"kind": "place", "google_place_id": "ChIJ1", "name": "Chin Chin"}
        ]}
        """)
        #expect(response.results.count == 1)
        #expect(response.results.first?.name == "Chin Chin")
    }

    @Test("an older deployment with no results[] decodes as empty, not as a failure")
    func missingResultsField() throws {
        let response = try decode(PlacesAutocompleteResponse.self, #"{"stub": true, "predictions": []}"#)
        #expect(response.results.isEmpty)
        #expect(response.stub)
    }

    @Test("manual rows render name + suburb only — they carry no distance by construction")
    func manualRowShape() throws {
        let response = try decode(PlacesAutocompleteResponse.self, """
        {"stub": false, "results": [{"kind": "manual", "id": "8E7A0A5C-0000-4000-8000-000000000001",
          "name": "Marg's Diner", "city": "Fitzroy", "match_score": 0.85}]}
        """)
        let result = try #require(response.results.first)
        let row = RestaurantRowModel(result)
        #expect(row.name == "Marg's Diner")
        #expect(row.secondary == "Fitzroy")
        #expect(row.distanceMeters == nil)
        // Already a row ⇒ selecting costs nothing.
        #expect(row.selection == .restaurant(id: UUID(uuidString: "8E7A0A5C-0000-4000-8000-000000000001")!))
    }

    @Test("an empty city is 'no locality', not an empty second line")
    func manualEmptyCity() throws {
        let match = try decode(ManualRestaurantMatch.self, """
        {"id": "8E7A0A5C-0000-4000-8000-000000000001", "name": "Marg's", "city": "", "match_score": 1}
        """)
        #expect(match.locality == nil)
        #expect(RestaurantRowModel(.manual(match)).secondary == nil)
    }

    @Test("a place row resolves through op=details")
    func placeRowShape() {
        let row = RestaurantRowModel(.place(PlacePrediction(
            googlePlaceID: "ChIJ1", name: "Chin Chin",
            secondary: "125 Flinders Ln, Melbourne VIC", distanceMeters: 540
        )))
        #expect(row.selection == .place(googlePlaceID: "ChIJ1"))
        #expect(row.distanceMeters == 540)
        #expect(row.telemetryKind == "place")
    }

    @Test("row ids are unique across kinds so one ForEach can render the flat list")
    func rowIdentity() {
        let uuid = UUID()
        let manual = RestaurantSearchResult.manual(ManualRestaurantMatch(id: uuid, name: "A"))
        let place = RestaurantSearchResult.place(PlacePrediction(googlePlaceID: uuid.uuidString, name: "A"))
        #expect(manual.id != place.id)
    }

    // MARK: - nearby, and the stub trap

    @Test("in LIVE mode a nearby row carries a real restaurants.id — zero round-trips to select")
    func nearbyLive() throws {
        let response = try decode(PlacesNearbyResponse.self, """
        {"stub": false, "source": "db", "restaurants": [
          {"id": "8E7A0A5C-0000-4000-8000-000000000009", "google_place_id": "ChIJ1",
           "name": "Chin Chin", "address": "125 Flinders Ln", "city": "Melbourne VIC",
           "cuisine": "Thai", "cover_url": null, "distance_meters": 540}
        ]}
        """)
        let nearby = try #require(response.restaurants.first)
        let row = try #require(RestaurantRowModel(nearby, stub: response.stub))
        #expect(row.selection == .restaurant(id: UUID(uuidString: "8E7A0A5C-0000-4000-8000-000000000009")!))
        #expect(SearchDistance.string(meters: row.distanceMeters, locale: Locale(identifier: "en_AU")) == "540 m")
    }

    @Test("in STUB mode `id` is the place id, NOT a row id — it must resolve via op=details first")
    func nearbyStub() throws {
        let response = try decode(PlacesNearbyResponse.self, """
        {"stub": true, "source": "db", "restaurants": [
          {"id": "seed_place_chintamani", "google_place_id": "seed_place_chintamani",
           "name": "Chin Chin", "address": "125 Flinders Ln", "city": "Melbourne VIC",
           "distance_meters": 1240}
        ]}
        """)
        #expect(response.stub)
        let nearby = try #require(response.restaurants.first)
        let row = try #require(RestaurantRowModel(nearby, stub: true))
        #expect(row.selection == .place(googlePlaceID: "seed_place_chintamani"))
    }

    @Test("a live row with neither a UUID id nor a place id is dropped, not rendered as a dead end")
    func nearbyUnusableRow() {
        let unusable = NearbyRestaurant(rawID: "not-a-uuid", googlePlaceID: nil, name: "Ghost")
        #expect(unusable.selection(stub: false) == nil)
        #expect(RestaurantRowModel(unusable, stub: false) == nil)
    }

    // MARK: - details

    @Test("op=details returns a partial restaurants projection — no created_at, so not a Restaurant")
    func detailsDecodes() throws {
        let response = try decode(PlacesDetailsResponse.self, """
        {"stub": false, "restaurant": {"id": "8E7A0A5C-0000-4000-8000-000000000002",
          "google_place_id": "ChIJ1", "name": "Chin Chin", "address": "125 Flinders Ln",
          "city": "Melbourne VIC", "cuisine": "Thai", "cover_url": null}}
        """)
        let picked = PickedRestaurant(response.restaurant)
        #expect(picked.name == "Chin Chin")
        #expect(picked.locality == "Melbourne VIC")
    }

    // MARK: - Distance rendering (§11.1)

    @Test("distance never renders as 0 km and never renders at all when absent", arguments: [
        (nil, nil),
        (0.0, "10 m"),
        (4.0, "10 m"),
        (44.0, "40 m"),
        (46.0, "50 m"),
        (540.0, "540 m"),
        (949.0, "950 m"),
        (994.0, "990 m"),
        (995.0, "1.0 km"),
        (1240.0, "1.2 km"),
        (12500.0, "12.5 km"),
        (-5.0, nil)
    ] as [(Double?, String?)])
    func distanceStrings(meters: Double?, expected: String?) {
        #expect(SearchDistance.string(meters: meters, locale: Locale(identifier: "en_AU")) == expected)
    }

    @Test("a non-finite distance renders nothing rather than 'inf km'")
    func nonFiniteDistance() {
        #expect(SearchDistance.string(meters: .infinity) == nil)
        #expect(SearchDistance.string(meters: .nan) == nil)
    }

    // MARK: - Nearby cache (§1.2)

    @Test("nearby is cached per rounded origin and expires")
    func nearbyCache() async {
        let cache = NearbyCache(ttl: .milliseconds(60))
        let origin = SearchOrigin(latitude: -37.8159, longitude: 144.9686)
        let rows = [RestaurantRowModel(recent: SearchFixtures.restaurant(name: "Chin Chin"))]

        await cache.store(rows, for: origin)
        #expect(await cache.value(for: origin)?.count == 1)
        // GPS jitter under ~100 m must hit the same entry rather than re-billing Google.
        #expect(await cache.value(for: SearchOrigin(latitude: -37.81594, longitude: 144.96864)) != nil)
        // A different suburb must not.
        #expect(await cache.value(for: SearchOrigin(latitude: -37.9, longitude: 145.1)) == nil)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(await cache.value(for: origin) == nil)
    }
}

enum SearchFixtures {
    static func restaurant(
        id: UUID = UUID(),
        name: String,
        city: String = "Fitzroy",
        source: RestaurantSource = .manual
    ) -> Restaurant {
        Restaurant(
            id: id,
            source: source,
            googlePlaceID: source == .places ? "ChIJ\(name)" : nil,
            name: name,
            address: nil,
            city: city,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
