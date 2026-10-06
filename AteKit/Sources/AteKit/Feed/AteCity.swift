import Foundation

/// **A city** (0046–0048) — one row of `feed_cities()`, `resolve_city()`, `my_entry_cities()` or
/// `search_cities()`: what the Feed is about, and what the Journal and Search filter by.
///
/// `city` is the slug (`"melbourne"`, `"gold-coast"`): what is persisted and sent back as `p_city`.
/// `name` is the display string. `isNearby`/`distanceM` only come from `resolve_city`.
public struct AteCity: Sendable, Hashable, Identifiable, Decodable {
    public let city: String
    public let name: String
    public let region: String?
    public let entryCount: Int
    /// `resolve_city` only: the point was inside this city's radius. `false` for the nearest city
    /// with food, and for the busiest city when there was no point at all.
    public let isNearby: Bool

    public var id: String { city }

    public init(city: String, name: String, region: String? = nil, entryCount: Int = 0, isNearby: Bool = false) {
        self.city = city
        self.name = name
        self.region = region
        self.entryCount = entryCount
        self.isNearby = isNearby
    }

    enum CodingKeys: String, CodingKey {
        case city, name, region
        case entryCount = "entry_count"
        case placeCount = "place_count"
        case dishCount = "dish_count"
        case isNearby = "is_nearby"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        city = try container.decode(String.self, forKey: .city)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? city
        region = try container.decodeIfPresent(String.self, forKey: .region)
        // `feed_cities`/`my_entry_cities` count entries; `search_cities` counts places.
        entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount)
            ?? container.decodeIfPresent(Int.self, forKey: .placeCount)
            ?? container.decodeIfPresent(Int.self, forKey: .dishCount)
            ?? 0
        isNearby = try container.decodeIfPresent(Bool.self, forKey: .isNearby) ?? false
    }

    /// A display name as a slug — `"Gold Coast"` → `"gold-coast"` — for the in-memory readers that
    /// have names and no slugs. `nil` for nothing at all.
    public static func slug(for name: String?) -> String? {
        guard let name else { return nil }
        let words = name.lowercased().split { $0.isLetter == false && $0.isNumber == false }
        return words.isEmpty ? nil : words.joined(separator: "-")
    }

    /// A slug's display name from a list, or the slug itself made readable when the list does not
    /// hold it — "gold-coast" is "Gold Coast".
    public static func displayName(for slug: String, in cities: [AteCity] = []) -> String {
        cities.first { $0.city == slug }?.name
            ?? slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The cities a typed search keeps, in the order given: any whose name or region contains it,
    /// ignoring case and accents ("ade" finds Adelaide, "vic" finds every Victorian city). An empty
    /// search keeps them all.
    public static func matching(_ cities: [AteCity], query: String) -> [AteCity] {
        guard let needle = searchKey(query) else { return cities }
        return cities.filter { city in
            [city.name, city.region ?? ""].contains { searchKey($0)?.contains(needle) == true }
        }
    }

    /// Whether a fixed answer beside the cities ("Near me", "Everywhere") stays under a typed search.
    public static func title(_ title: String, matches query: String) -> Bool {
        guard let needle = searchKey(query) else { return true }
        return searchKey(title)?.contains(needle) == true
    }

    private static func searchKey(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return key.isEmpty ? nil : key
    }

    /// Busiest first, then by name — the servers' own order, made true whatever a reader does.
    public static func ordered(_ cities: [AteCity]) -> [AteCity] {
        cities.sorted { ($0.entryCount, $1.name) > ($1.entryCount, $0.name) }
    }

    /// The same cities from the stand-in readers: every name that appears, counted.
    public static func counted(_ names: [String?]) -> [AteCity] {
        var counts: [String: (name: String, count: Int)] = [:]
        for name in names {
            guard let name, let slug = slug(for: name) else { continue }
            counts[slug, default: (name, 0)].count += 1
        }
        return ordered(counts.map { AteCity(city: $0.key, name: $0.value.name, entryCount: $0.value.count) })
    }
}

/// **What the Feed is about** (round 5, Eamon: "by default it should be set to 'near me' … but they
/// should be able to set the location to other cities"). Persisted per person as a string.
public enum FeedLocation: Hashable, Sendable {
    /// The city `resolve_city` puts the phone in — or, with no location, the busiest one.
    case nearMe
    case everywhere
    case city(String)

    public static let `default` = FeedLocation.nearMe

    /// How it is stored: two reserved words (never a slug — slugs are lowercase letters and
    /// hyphens) or the slug itself.
    public var stored: String {
        switch self {
        case .nearMe: "@near-me"
        case .everywhere: "@everywhere"
        case .city(let slug): slug
        }
    }

    public init(stored: String?) {
        switch stored {
        case nil, "@near-me": self = .nearMe
        case "@everywhere": self = .everywhere
        case let slug?: self = slug.isEmpty ? .nearMe : .city(slug)
        }
    }

    /// `location_kind` on `feed_location_changed`.
    public var telemetryName: String {
        switch self {
        case .nearMe: "near_me"
        case .everywhere: "everywhere"
        case .city: "city"
        }
    }
}
