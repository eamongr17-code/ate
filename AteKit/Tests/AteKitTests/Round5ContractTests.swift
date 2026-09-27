import Foundation
import PostgREST
import Supabase
import Testing

@testable import AteKit

/// **Round 5 backend** (migrations 0046–0048), against staging.
///
/// The contract the iOS lanes build to (`docs/backend/integration-design.md`):
/// - **City Feed:** `feed_cities()` lists the cities with food, `resolve_city(p_lat, p_lng)` picks
///   "near me", `get_entry_feed(…, p_city)` keeps one city.
/// - **Filters:** `my_entries` / `search_places` / `search_dishes` / `nearby_places` take `p_max_score`
///   beside `p_min_score` (a top of 5 is open: a 6 stays in) and `p_city`; `my_entry_cities()` and
///   `search_cities()` are the pickers.
/// - **Share link:** `get_entry_card(p_entry_id)` reads one entry, signed in or out.
/// - **Saved (0049):** `search_saved` takes the same range + city; `my_saved_cities()` is its picker.
///
/// It OWNS its data: one synthetic entry under the seeded DEMO account `jess`, body starting with the
/// `Contract round5 probe` marker, deleted at the end (and swept first). Needs 0046–0049 on staging.
@Suite("Round 5 — staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct Round5ContractTests {
    static let marker = "Contract round5 probe"
    static let author = (email: "jess@ate.test", password: "atedemo123")
    /// A seeded city far from staging's Melbourne-only catalogue: no place maps to it.
    static let elsewhere = "darwin"

    func signIn() async throws -> AteAPIClient {
        let supabase = StagingContract.makeClient()
        try await supabase.auth.signIn(email: Self.author.email, password: Self.author.password)
        return AteAPIClient(supabase: supabase)
    }

    func sweep(_ client: AteAPIClient) async throws {
        let me = try await client.requireCurrentUserID()
        try await client.supabase.from("entries").delete()
            .eq("author_id", value: me.uuidString.lowercased())
            .like("body", pattern: "\(Self.marker)%")
            .execute()
    }

    func refused(_ what: String, _ call: () async throws -> Void) async {
        do {
            try await call()
            Issue.record("\(what) was not refused")
        } catch {}
    }

    @Test("city feed + pickers + near me; range and city filters; the share-link read — signed in and out")
    func roundFive() async throws {
        try await StagingExclusive.shared.run {
            let jess = try await signIn()
            try await sweep(jess)
            do {
                try await drive(jess)
            } catch {
                try? await sweep(jess)
                throw error
            }
            try await sweep(jess)
        }
    }

    func drive(_ jess: AteAPIClient) async throws {
        let viewer = try await StagingContract.Backend.shared.client()
        let anon = AteAPIClient(supabase: StagingContract.makeClient())

        // A place with a city.
        let mapped: [PlaceCity] = try await jess.supabase.from("place_cities").select("restaurant_id,city")
            .order("restaurant_id").limit(1).execute().value
        let place = try #require(mapped.first, "staging holds no place in any city")
        let named: [Named] = try await jess.supabase.from("restaurants").select("name")
            .eq("id", value: place.restaurantID.uuidString.lowercased()).execute().value
        let placeName = try #require(named.first?.name)

        // The owned entry, sorted, its line marked a 6 by the author.
        let entry = UUID()
        let me = try await jess.requireCurrentUserID()
        try await jess.supabase.from("entries").insert(
            NewEntry(id: entry, authorID: me, body: "\(Self.marker). Gnocchi 4.5.",
                     restaurantID: place.restaurantID, createdAt: Date()),
            returning: .minimal
        ).execute()
        let _: Sorted = try await jess.supabase.functions.invoke("sort-entry", options: FunctionInvokeOptions(
            method: .post, body: ["entry_id": entry.uuidString.lowercased()]
        ))
        let card = try #require(try await cards(jess, entry).first)
        let line = try #require(card.items.first, "the sorter printed no line for \"Gnocchi 4.5\"")
        struct Patched: Decodable { let id: UUID }
        let patched: [Patched] = try await jess.supabase.from("reviews")
            .update(["score": 6.0], returning: .representation)
            .eq("id", value: line.reviewID.uuidString.lowercased()).select("id").execute().value
        #expect(patched.count == 1)

        // 0048 — the share-link read.
        #expect(try await cards(anon, entry).map(\.isMine) == [false], "anon reads a public entry")
        #expect(try await cards(viewer, entry).map(\.isMine) == [false])
        #expect(try await cards(jess, entry).map(\.isMine) == [true])
        #expect(try await cards(anon, UUID()).isEmpty, "unknown id → []")

        // 0046 — the city Feed.
        for who in [anon, viewer] {
            #expect(try await feed(who, city: place.city).contains(entry), "\(place.city) feed")
            #expect(try await feed(who, city: Self.elsewhere).contains(entry) == false)
            #expect(try await feed(who, city: nil).contains(entry), "no city = everywhere")
        }
        let cities: [City] = try await StagingRPC.rows(anon, "feed_cities")
        #expect(cities.map(\.entryCount) == cities.map(\.entryCount).sorted(by: >), "busiest first")
        let here = try #require(cities.first { $0.city == place.city }, "\(place.city) missing from feed_cities")
        #expect(here.entryCount >= 1)
        let near: [Resolved] = try await StagingRPC.rows(anon, "resolve_city", [
            "p_lat": .double(here.lat), "p_lng": .double(here.lng)
        ])
        #expect(near.map(\.city) == [place.city])
        #expect(near.first?.isNearby == true)
        let blind: [Resolved] = try await StagingRPC.rows(viewer, "resolve_city")
        #expect(blind.first?.isNearby == false, "no location → the busiest city, not near")
        let viewerCities: [City] = try await StagingRPC.rows(viewer, "feed_cities")
        #expect(blind.map(\.city) == Array(viewerCities.prefix(1)).map(\.city))

        // 0047 — Journal range + city.
        #expect(try await mine(jess, ["p_city": .string(place.city), "p_min_score": .double(4),
                                      "p_max_score": .double(5)]).contains(entry), "a top of 5 keeps the 6")
        #expect(try await mine(jess, ["p_max_score": .double(4.5)]).contains(entry) == false)
        #expect(try await mine(jess, ["p_min_score": .double(6)]).contains(entry))
        #expect(try await mine(jess, ["p_city": .string(Self.elsewhere)]).contains(entry) == false)
        let journalCities: [City] = try await StagingRPC.rows(jess, "my_entry_cities")
        #expect(journalCities.contains { $0.city == place.city && $0.entryCount >= 1 })

        // 0047 — Search city + range.
        let query = String(placeName.prefix(2))
        #expect(try await places(viewer, query, city: place.city).contains(place.restaurantID))
        #expect(try await places(viewer, query, city: Self.elsewhere).isEmpty)
        let searchCities: [City] = try await StagingRPC.rows(viewer, "search_cities")
        #expect(searchCities.contains { $0.city == place.city && ($0.placeCount ?? 0) >= 1 })
        let ranged: [Rated] = try await StagingRPC.rows(viewer, "search_places", [
            "p_query": .string(query), "p_limit": .integer(50), "p_min_score": .double(2), "p_max_score": .double(3.5)
        ])
        #expect(ranged.allSatisfy { ($0.avgRating ?? 0) >= 2 && ($0.avgRating ?? 9) <= 3.5 }, "\(ranged)")

        try await driveSaved(jess, dish: line.dishID, entry: entry, city: place.city)

        await refused("anon my_entries") { _ = try await mine(anon, ["p_city": .string(place.city)]) }
        await refused("anon search_cities") { let _: [City] = try await StagingRPC.rows(anon, "search_cities") }
    }

    /// 0049 — the Saved shelf's range + city. Saves the probe's dish and takes the save back off unless
    /// jess already had it (a save outlives the entry it came from, so the sweep would not).
    func driveSaved(_ jess: AteAPIClient, dish: UUID, entry: UUID, city: String) async throws {
        let had = try await StagingRPC.raw(jess, "is_dish_saved", ["p_dish_id": StagingRPC.id(dish)]) == "true"
        _ = try await jess.supabase.rpc("save_dish", params: [
            "p_dish_id": StagingRPC.id(dish), "p_source_entry_id": StagingRPC.id(entry)
        ]).execute()
        do {
            func shelf(_ params: [String: AnyJSON]) async throws -> [SavedRow] {
                var params = params
                params["p_query"] = .null
                params["p_limit"] = .integer(50)
                return try await StagingRPC.rows(jess, "search_saved", params)
            }
            let mine = try #require(try await shelf(["p_city": .string(city)]).first { $0.dishID == dish })
            #expect(try await shelf(["p_city": .string(Self.elsewhere)]).isEmpty)
            let score = try #require(mine.dishScore, "the probe's dish has a score")
            #expect(try await shelf(["p_min_score": .double(score), "p_max_score": .double(5)])
                .contains { $0.dishID == dish }, "a top of 5 is open")
            let banded = try await shelf(["p_min_score": .double(3), "p_max_score": .double(4.5)])
            #expect(banded.allSatisfy { ($0.dishScore ?? 0) >= 3 && ($0.dishScore ?? 9) <= 4.5 }, "\(banded)")
            let savedCities: [SavedCity] = try await StagingRPC.rows(jess, "my_saved_cities")
            #expect(savedCities.contains { $0.city == city && $0.dishCount >= 1 })
        } catch {
            if had == false {
                _ = try? await jess.supabase.rpc("unsave_dish", params: ["p_dish_id": StagingRPC.id(dish)]).execute()
            }
            throw error
        }
        if had == false {
            _ = try await jess.supabase.rpc("unsave_dish", params: ["p_dish_id": StagingRPC.id(dish)]).execute()
        }
    }

    // MARK: - Calls

    func cards(_ client: AteAPIClient, _ entry: UUID) async throws -> [EntryRow] {
        try await StagingRPC.rows(client, "get_entry_card", ["p_entry_id": StagingRPC.id(entry)])
    }

    func feed(_ client: AteAPIClient, city: String?) async throws -> [UUID] {
        let rows: [EntryRow] = try await StagingRPC.rows(client, "get_entry_feed", [
            "p_page_size": .integer(50), "p_city": StagingRPC.text(city)
        ])
        return rows.map(\.id)
    }

    func mine(_ client: AteAPIClient, _ params: [String: AnyJSON]) async throws -> [UUID] {
        var params = params
        params["p_limit"] = .integer(100)
        let rows: [IDOnly] = try await StagingRPC.rows(client, "my_entries", params)
        return rows.map(\.id)
    }

    func places(_ client: AteAPIClient, _ query: String, city: String) async throws -> [UUID] {
        let rows: [Rated] = try await StagingRPC.rows(client, "search_places", [
            "p_query": .string(query), "p_limit": .integer(50), "p_city": .string(city)
        ])
        return rows.map(\.restaurantID)
    }

    // MARK: - Wire rows

    struct Named: Decodable, Sendable { let name: String }

    struct SavedRow: Decodable, Sendable {
        let dishID: UUID
        let dishScore: Double?
        enum CodingKeys: String, CodingKey {
            case dishID = "dish_id"
            case dishScore = "dish_score"
        }
    }

    struct SavedCity: Decodable, Sendable {
        let city: String
        let dishCount: Int
        enum CodingKeys: String, CodingKey {
            case city
            case dishCount = "dish_count"
        }
    }
    struct Sorted: Decodable, Sendable { let ok: Bool? }

    struct PlaceCity: Decodable, Sendable {
        let restaurantID: UUID
        let city: String
        enum CodingKeys: String, CodingKey {
            case city
            case restaurantID = "restaurant_id"
        }
    }

    struct IDOnly: Decodable, Sendable { let id: UUID }

    struct Item: Decodable, Sendable {
        let reviewID: UUID
        let dishID: UUID
        enum CodingKeys: String, CodingKey {
            case reviewID = "review_id"
            case dishID = "dish_id"
        }
    }

    struct EntryRow: Decodable, Sendable {
        let id: UUID
        let isMine: Bool
        let items: [Item]
        enum CodingKeys: String, CodingKey {
            case id, items
            case isMine = "is_mine"
        }
    }

    struct City: Decodable, Sendable {
        let city: String
        let name: String
        let region: String
        let lat: Double
        let lng: Double
        let entryCount: Int
        let placeCount: Int?
        enum CodingKeys: String, CodingKey {
            case city, name, region, lat, lng
            case entryCount = "entry_count"
            case placeCount = "place_count"
        }
        init(from decoder: any Decoder) throws {
            let row = try decoder.container(keyedBy: CodingKeys.self)
            city = try row.decode(String.self, forKey: .city)
            name = try row.decode(String.self, forKey: .name)
            region = try row.decode(String.self, forKey: .region)
            // feed_cities carries the centre; the two pickers do not.
            lat = try row.decodeIfPresent(Double.self, forKey: .lat) ?? 0
            lng = try row.decodeIfPresent(Double.self, forKey: .lng) ?? 0
            entryCount = try row.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
            placeCount = try row.decodeIfPresent(Int.self, forKey: .placeCount)
        }
    }

    struct Resolved: Decodable, Sendable {
        let city: String
        let entryCount: Int
        let distanceM: Double?
        let isNearby: Bool
        enum CodingKeys: String, CodingKey {
            case city
            case entryCount = "entry_count"
            case distanceM = "distance_m"
            case isNearby = "is_nearby"
        }
    }

    struct Rated: Decodable, Sendable {
        let restaurantID: UUID
        let avgRating: Double?
        enum CodingKeys: String, CodingKey {
            case restaurantID = "restaurant_id"
            case avgRating = "avg_rating"
        }
    }
}
