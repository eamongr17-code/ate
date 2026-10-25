import Foundation
import Supabase

/// **The dish map's reads** (0088, `nearby-map.html` option A): the pins and the sheet under them.
///
/// Both read the same places — the ones in the visible box with a dish anyone can see, nearest the
/// middle first, at most 200 — so the sheet never lists a dish whose pin is not on the map.
public protocol DishMapReading: Sendable {
    /// `map_places` over a box: the pins. `origin` (the phone) only adds each place's distance.
    func places(in box: MapBox, origin: SearchOrigin?, limit: Int) async throws -> [MapPlace]
    /// `map_places` with no box: the `limit` places nearest `origin`, however far — what the map
    /// opens framed on, so it is never empty. With no origin (location off), around the place most
    /// written about.
    func nearest(to origin: SearchOrigin?, limit: Int) async throws -> [MapPlace]
    /// `map_dishes`: every dish at the places in `box`, best first, keyset-paged.
    func dishes(in box: MapBox, origin: SearchOrigin?, after cursor: MapDishCursor?, pageSize: Int) async throws
        -> MapDishPage
}

/// A latitude/longitude rectangle — the map's visible region, as the server reads it.
public struct MapBox: Sendable, Hashable {
    public let minLatitude: Double
    public let minLongitude: Double
    public let maxLatitude: Double
    public let maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = max(-90, min(minLatitude, maxLatitude))
        self.maxLatitude = min(90, max(minLatitude, maxLatitude))
        self.minLongitude = max(-180, min(minLongitude, maxLongitude))
        self.maxLongitude = min(180, max(minLongitude, maxLongitude))
    }

    /// The box around a centre and a span in degrees (MapKit's region).
    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.init(
            minLatitude: centerLatitude - latitudeDelta / 2, minLongitude: centerLongitude - longitudeDelta / 2,
            maxLatitude: centerLatitude + latitudeDelta / 2, maxLongitude: centerLongitude + longitudeDelta / 2
        )
    }

    public var centerLatitude: Double { (minLatitude + maxLatitude) / 2 }
    public var centerLongitude: Double { (minLongitude + maxLongitude) / 2 }
    public var latitudeDelta: Double { maxLatitude - minLatitude }
    public var longitudeDelta: Double { maxLongitude - minLongitude }

    /// The square round a point, `radiusMeters` from its middle to each edge: Near me, and the map's
    /// opening view.
    public static func around(_ point: SearchOrigin, radiusMeters: Double) -> MapBox {
        let metersPerDegree = 111_320.0
        let latitudeDelta = 2 * radiusMeters / metersPerDegree
        let shrink = max(cos(point.latitude * .pi / 180), 0.01)
        return MapBox(
            centerLatitude: point.latitude, centerLongitude: point.longitude,
            latitudeDelta: latitudeDelta, longitudeDelta: latitudeDelta / shrink
        )
    }

    /// How many metres the box is across, east to west through its middle.
    public var widthMeters: Double {
        longitudeDelta * 111_320 * max(cos(centerLatitude * .pi / 180), 0)
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        (minLatitude...maxLatitude).contains(latitude) && (minLongitude...maxLongitude).contains(longitude)
    }

    /// The smallest box holding every point, grown by `padding` of its span on each side (and at
    /// least `minimumSpan` degrees across), so pins at the edge are not under the chrome.
    public static func fitting(
        _ points: [SearchOrigin], padding: Double = 0.2, minimumSpan: Double = 0.01
    ) -> MapBox? {
        guard let first = points.first else { return nil }
        var box = (minLat: first.latitude, maxLat: first.latitude, minLng: first.longitude, maxLng: first.longitude)
        for point in points.dropFirst() {
            box.minLat = min(box.minLat, point.latitude)
            box.maxLat = max(box.maxLat, point.latitude)
            box.minLng = min(box.minLng, point.longitude)
            box.maxLng = max(box.maxLng, point.longitude)
        }
        let latSpan = max(box.maxLat - box.minLat, minimumSpan)
        let lngSpan = max(box.maxLng - box.minLng, minimumSpan)
        return MapBox(
            centerLatitude: (box.minLat + box.maxLat) / 2, centerLongitude: (box.minLng + box.maxLng) / 2,
            latitudeDelta: latSpan * (1 + 2 * padding), longitudeDelta: lngSpan * (1 + 2 * padding)
        )
    }
}

/// One pin: a place, its best dish (the pin's photo and its one badge, the score) and the next
/// dish's photo, the one stacked behind it — two photos at most.
public struct MapPlace: Sendable, Hashable, Codable, Identifiable {
    public let restaurantID: UUID
    public let name: String
    public let locality: String?
    public let latitude: Double
    public let longitude: Double
    /// Metres from the phone; `nil` when the read had no point.
    public let distanceMeters: Int?
    public let dishCount: Int
    public let topDishID: UUID
    public let topDishName: String
    /// The best dish's average. `nil` when nobody scored it — never inferred.
    public let topScore: Double?
    public let topCoverURLString: String?
    public let secondCoverURLString: String?

    public var id: UUID { restaurantID }
    public var origin: SearchOrigin { SearchOrigin(latitude: latitude, longitude: longitude) }

    public init(
        restaurantID: UUID, name: String, locality: String? = nil, latitude: Double, longitude: Double,
        distanceMeters: Int? = nil, dishCount: Int = 1, topDishID: UUID = UUID(), topDishName: String = "",
        topScore: Double? = nil, topCoverURLString: String? = nil, secondCoverURLString: String? = nil
    ) {
        self.restaurantID = restaurantID
        self.name = name
        self.locality = locality
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.dishCount = dishCount
        self.topDishID = topDishID
        self.topDishName = topDishName
        self.topScore = topScore
        self.topCoverURLString = topCoverURLString
        self.secondCoverURLString = secondCoverURLString
    }

    enum CodingKeys: String, CodingKey {
        case name, locality, latitude, longitude
        case restaurantID = "restaurant_id"
        case distanceMeters = "distance_m"
        case dishCount = "dish_count"
        case topDishID = "top_dish_id"
        case topDishName = "top_dish_name"
        case topScore = "top_score"
        case topCoverURLString = "top_cover_url"
        case secondCoverURLString = "second_cover_url"
    }
}

/// One row of the sheet: a dish, its place and how far it is.
public struct MapDish: Sendable, Hashable, Codable, Identifiable {
    public let dishID: UUID
    public let name: String
    public let score: Double?
    public let reviewCount: Int
    public let coverURLString: String?
    public let restaurantID: UUID
    public let placeName: String
    public let locality: String?
    public let distanceMeters: Int?

    public var id: UUID { dishID }
    public var cursor: MapDishCursor { MapDishCursor(score: score, reviewCount: reviewCount, dishID: dishID) }

    public init(
        dishID: UUID, name: String, score: Double? = nil, reviewCount: Int = 1, coverURLString: String? = nil,
        restaurantID: UUID, placeName: String, locality: String? = nil, distanceMeters: Int? = nil
    ) {
        self.dishID = dishID
        self.name = name
        self.score = score
        self.reviewCount = reviewCount
        self.coverURLString = coverURLString
        self.restaurantID = restaurantID
        self.placeName = placeName
        self.locality = locality
        self.distanceMeters = distanceMeters
    }

    enum CodingKeys: String, CodingKey {
        case score, locality
        case dishID = "dish_id"
        case name = "dish_name"
        case reviewCount = "review_count"
        case coverURLString = "cover_url"
        case restaurantID = "restaurant_id"
        case placeName = "place_name"
        case distanceMeters = "distance_m"
    }
}

/// `map_dishes`' order is `score desc nulls last, review_count desc, dish_id` — three values from the
/// last row. The server orders; the client never re-sorts a paged list.
public struct MapDishCursor: Sendable, Hashable {
    public let score: Double?
    public let reviewCount: Int
    public let dishID: UUID

    public init(score: Double?, reviewCount: Int, dishID: UUID) {
        self.score = score
        self.reviewCount = reviewCount
        self.dishID = dishID
    }
}

public struct MapDishPage: Sendable {
    public let items: [MapDish]
    public let nextCursor: MapDishCursor?

    public init(items: [MapDish], requestedLimit: Int) {
        self.items = items
        self.nextCursor = items.count < requestedLimit ? nil : items.last?.cursor
    }
}

/// The live reads: `map_places` and `map_dishes` (0088). Signed in only, as the Feed is.
public struct DishMapClient: DishMapReading {
    /// `map_places` clamps `p_limit` at 200.
    public static let maximumPlaces = 200
    /// `map_dishes` clamps `p_limit` at 50.
    public static let maximumPageSize = 50

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func places(in box: MapBox, origin: SearchOrigin?, limit: Int) async throws -> [MapPlace] {
        var parameters = Self.boxParameters(box, origin: origin)
        parameters["p_limit"] = .integer(min(Self.maximumPlaces, max(1, limit)))
        return try await read("map_places", parameters)
    }

    public func nearest(to origin: SearchOrigin?, limit: Int) async throws -> [MapPlace] {
        try await read("map_places", [
            "p_lat": origin.map { .double($0.latitude) } ?? .null,
            "p_lng": origin.map { .double($0.longitude) } ?? .null,
            "p_limit": .integer(min(Self.maximumPlaces, max(1, limit)))
        ])
    }

    public func dishes(
        in box: MapBox, origin: SearchOrigin?, after cursor: MapDishCursor?, pageSize: Int
    ) async throws -> MapDishPage {
        let limit = min(Self.maximumPageSize, max(1, pageSize))
        var parameters = Self.boxParameters(box, origin: origin)
        parameters["p_limit"] = .integer(limit)
        // Only with a cursor: its score is legitimately null for an unscored dish, so presence decides.
        if let cursor {
            parameters["p_cursor_score"] = cursor.score.map { .double($0) } ?? .null
            parameters["p_cursor_review_count"] = .integer(cursor.reviewCount)
            parameters["p_cursor_dish_id"] = .string(cursor.dishID.uuidString.lowercased())
        }
        let rows: [MapDish] = try await read("map_dishes", parameters)
        return MapDishPage(items: rows, requestedLimit: limit)
    }

    /// POST, never GET: the coordinates go in the body, so they never land in a URL log.
    private func read<Row: Decodable>(_ function: String, _ parameters: [String: AnyJSON]) async throws -> [Row] {
        guard api.isSignedIn else { throw AteAPIError.notAuthenticated }
        let data = try await api.supabase.rpc(function, params: parameters).execute().data
        return try JSONDecoder().decode([Row].self, from: data)
    }

    private static func boxParameters(_ box: MapBox, origin: SearchOrigin?) -> [String: AnyJSON] {
        [
            "p_min_lat": .double(box.minLatitude),
            "p_min_lng": .double(box.minLongitude),
            "p_max_lat": .double(box.maxLatitude),
            "p_max_lng": .double(box.maxLongitude),
            "p_lat": origin.map { .double($0.latitude) } ?? .null,
            "p_lng": origin.map { .double($0.longitude) } ?? .null
        ]
    }
}
