import Foundation

/// **Where a place page sends you to see the place on a map.** Apple Maps always; Google Maps too
/// when it is on the phone (the app asks which).
///
/// A place with a point opens on the point, labelled with its name, and Google Maps opens its exact
/// listing by place id. A hand-added place has no point (0014), so both apps search for the name and
/// address instead — every place opens somewhere, and nothing is guessed.
public struct PlaceMapLink: Sendable, Equatable {
    public let name: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    public let googlePlaceID: String?

    public init(name: String, address: String?, latitude: Double?, longitude: Double?, googlePlaceID: String?) {
        self.name = name
        self.address = address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.latitude = latitude
        self.longitude = longitude
        self.googlePlaceID = googlePlaceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public init(_ summary: PlaceSummary) {
        self.init(name: summary.name, address: summary.address, latitude: summary.latitude,
                  longitude: summary.longitude, googlePlaceID: summary.googlePlaceID)
    }

    /// The point, when there is a real one (never 0,0, never out of range).
    public var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              (latitude, longitude) != (0, 0) else { return nil }
        return (latitude, longitude)
    }

    /// What either app searches for when there is no point: the name and the address (the address
    /// alone when it already starts with the name), or the name when there is no address.
    var searchText: String {
        guard let address else { return name }
        return address.localizedCaseInsensitiveContains(name) ? address : "\(name), \(address)"
    }

    /// The street the place is on ("1203 High St"): the address's first line when it reads as one
    /// (it has a number, and is not a suburb line such as "Melbourne VIC 3000"). `nil` otherwise, and
    /// the chip then says "Map".
    public var street: String? {
        guard let line = address?.split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces).nilIfEmpty,
              line.contains(where: \.isNumber),
              line.range(of: #"\b[A-Za-z]{2,3}\s+\d{4}$"#, options: .regularExpression) == nil,
              line.caseInsensitiveCompare(name) != .orderedSame
        else { return nil }
        return line
    }

    /// Apple Maps: a pin named for the place on its point, else a search.
    public var appleMapsURL: URL {
        if let point = coordinate {
            return Self.url("https://maps.apple.com/", [("ll", Self.degrees(point)), ("q", name)])
        }
        return Self.url("https://maps.apple.com/", [("q", searchText)])
    }

    /// Google Maps, in its app (`comgooglemapsurl://` opens a Maps URL there). The place id picks the
    /// listing; `query` is what Google falls back on without one.
    public var googleMapsURL: URL {
        let query: [(String, String)]
        if let googlePlaceID {
            query = [("query", name), ("query_place_id", googlePlaceID)]
        } else if let point = coordinate {
            query = [("query", Self.degrees(point))]
        } else {
            query = [("query", searchText)]
        }
        return Self.url("comgooglemapsurl://www.google.com/maps/search/", [("api", "1")] + query)
    }

    private static func degrees(_ point: (latitude: Double, longitude: Double)) -> String {
        String(format: "%.7f,%.7f", point.latitude, point.longitude)
    }

    /// Every value escaped but letters, digits, `-._~` and the comma between degrees, so a name with
    /// `&`, `+` or `#` in it ("Bar & Grill") stays one value.
    private static func url(_ base: String, _ query: [(String, String)]) -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~,")
        let pairs = query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        return URL(string: base + "?" + pairs.joined(separator: "&"))!
    }

    /// Asked before offering Google Maps (listed under `LSApplicationQueriesSchemes`).
    public static let googleMapsProbe = URL(string: "comgooglemaps://")!
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
