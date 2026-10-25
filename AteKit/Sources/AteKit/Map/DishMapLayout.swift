import Foundation

/// **Which places get a photo pin** (`nearby-map.html`, "Busy streets"): restaurants sit shoulder to
/// shoulder, so the photos cannot all fit. The best-rated places take photo pins, only as many as fit
/// without touching; every other place is a dot. Zooming in spreads the points, so more fit.
///
/// Pure, so it is tested here and the map view only projects points and draws the answer.
public enum DishMapLayout {
    /// One place, where the map draws it (points, in the map view's space).
    public struct Candidate: Sendable, Hashable {
        public let id: UUID
        /// Points from the map view's leading edge.
        public let across: Double
        /// Points from the map view's top.
        public let down: Double
        public let score: Double?
        public let dishCount: Int

        public init(id: UUID, across: Double, down: Double, score: Double?, dishCount: Int) {
            self.id = id
            self.across = across
            self.down = down
            self.score = score
            self.dishCount = dishCount
        }
    }

    /// Centre to centre: a 48pt photo, its stacked photo and its score need this much room.
    public static let spacing: Double = 66
    /// More photos than this is a wall of food, not a map.
    public static let maximumPhotos = 12

    /// The ids that get a photo pin. The selected place always does (it was tapped, so it grows into
    /// its photos), then the rest best first while they stay `spacing` apart from every photo
    /// already placed. Ties go to the place with more dishes, then the id, so a redraw never swaps.
    public static func photoPins(
        _ candidates: [Candidate],
        selected: UUID? = nil,
        spacing: Double = DishMapLayout.spacing,
        maximum: Int = DishMapLayout.maximumPhotos
    ) -> Set<UUID> {
        var placed: [Candidate] = []
        if let selected, let pick = candidates.first(where: { $0.id == selected }) {
            placed.append(pick)
        }
        for candidate in candidates.sorted(by: isRankedBefore) {
            guard placed.count < maximum else { break }
            guard candidate.id != selected else { continue }
            let clear = placed.allSatisfy { other in
                let dx = other.across - candidate.across
                let dy = other.down - candidate.down
                return (dx * dx + dy * dy).squareRoot() >= spacing
            }
            if clear { placed.append(candidate) }
        }
        return Set(placed.map(\.id))
    }

    static func isRankedBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        let left = a.score ?? -1
        let right = b.score ?? -1
        if left != right { return left > right }
        if a.dishCount != b.dishCount { return a.dishCount > b.dishCount }
        return a.id.uuidString < b.id.uuidString
    }
}

/// **The sheet's title**: "Dishes near you" while you are on the map; once it has been dragged off
/// you, the suburb in the middle of it ("Dishes in Carlton"). Never "N dishes on the map", which
/// stops being true the moment the map moves.
public enum DishMapTitle: Sendable, Equatable {
    case nearYou
    case inArea(String)

    public var text: String {
        switch self {
        case .nearYou: "Dishes near you"
        case .inArea(let area): "Dishes in \(area)"
        }
    }

    /// `area` is the suburb under the map's centre, when known. With the phone in view it is near
    /// you; anywhere else (or with no fix at all) it is the area, once the area is known.
    public static func resolve(box: MapBox, phone: SearchOrigin?, area: String?) -> DishMapTitle {
        if let phone, box.contains(latitude: phone.latitude, longitude: phone.longitude) { return .nearYou }
        guard let area, area.isEmpty == false else { return .nearYou }
        return .inArea(area)
    }
}

/// How far a dish is, the way the sheet prints it: "350 m", "1.3 km", "12 km".
public enum MapDistance {
    public static func text(meters: Int) -> String {
        switch meters {
        case ..<1000: "\(max(10, (meters + 5) / 10 * 10)) m"
        case ..<10000: String(format: "%.1f km", Double(meters) / 1000)
        default: "\(Int((Double(meters) / 1000).rounded())) km"
        }
    }
}
