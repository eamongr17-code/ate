import Foundation

/// **How the map draws its places** (`nearby-map-2.html`, "Zooming"): restaurants sit shoulder to
/// shoulder, so the photos cannot all fit.
///
/// - Wider than ``dotsOnlyWidth`` (a whole city or more), every place is a dot.
/// - Closer in, the best-rated places take photo pins, only as many as fit without touching; every
///   other place is a dot. A dot that would touch a photo joins it (no dot ever sits on a picture).
/// - Dots that would touch each other are one dot, a little bigger the more places it holds; tapped,
///   the map zooms into it, and it splits into dots, then photos.
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

    /// A dot: one place, or several close together.
    public struct Dot: Sendable, Hashable, Identifiable {
        /// The places it holds, best first.
        public let members: [UUID]
        public let across: Double
        public let down: Double

        /// The best place's id: stable while the same places share the dot.
        public var id: UUID { members[0] }
    }

    public struct Arrangement: Sendable, Equatable {
        public var photos: Set<UUID> = []
        public var dots: [Dot] = []

        public init(photos: Set<UUID> = [], dots: [Dot] = []) {
            self.photos = photos
            self.dots = dots
        }
    }

    /// Centre to centre: a 48pt photo, its stacked photo and its score need this much room.
    public static let spacing: Double = 66
    /// A dot this close to a photo's middle would sit on it, so it joins the photo.
    public static let photoClearance: Double = 40
    /// Dots closer than this are one dot.
    public static let dotSpacing: Double = 22
    /// More photos than this is a wall of food, not a map.
    public static let maximumPhotos = 12
    /// A map wider than this (metres across) shows dots only.
    public static let dotsOnlyWidth: Double = 25_000

    /// Everything on screen: the photos and the dots. `widthMeters` is how far the map spans across.
    public static func arrange(
        _ candidates: [Candidate], selected: UUID? = nil, widthMeters: Double
    ) -> Arrangement {
        var photos: Set<UUID> = []
        if widthMeters > dotsOnlyWidth {
            // Far out, only a tapped place grows into its photos.
            if let selected, candidates.contains(where: { $0.id == selected }) { photos = [selected] }
        } else {
            photos = photoPins(candidates, selected: selected)
        }
        let placed = candidates.filter { photos.contains($0.id) }
        let loose = candidates.sorted(by: isRankedBefore).filter { candidate in
            photos.contains(candidate.id) == false
                && placed.allSatisfy { distance($0, candidate) >= photoClearance }
        }
        return Arrangement(photos: photos, dots: cluster(loose))
    }

    /// The same, for places read past the screen's edges (``MapBox/grown(by:)``) as well: those on
    /// screen are arranged as above, and those off it are dots only, so a photo is never spent off
    /// screen and a dot never sits on a photo at the edge. Panned into view, a place is already there
    /// and moves with the map; once the map stops, it grows into its photo if it has room.
    public static func arrange(
        _ candidates: [Candidate], selected: UUID? = nil, widthMeters: Double, screenWidth: Double, screenHeight: Double
    ) -> Arrangement {
        let isOnScreen = { (candidate: Candidate) in
            (0...screenWidth).contains(candidate.across) && (0...screenHeight).contains(candidate.down)
        }
        var arrangement = arrange(
            candidates.filter { isOnScreen($0) || $0.id == selected }, selected: selected, widthMeters: widthMeters
        )
        let placed = candidates.filter { arrangement.photos.contains($0.id) }
        let beyond = candidates.sorted(by: isRankedBefore).filter { candidate in
            isOnScreen(candidate) == false && candidate.id != selected
                && placed.allSatisfy { distance($0, candidate) >= photoClearance }
        }
        arrangement.dots += cluster(beyond)
        return arrangement
    }

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
            if placed.allSatisfy({ distance($0, candidate) >= spacing }) { placed.append(candidate) }
        }
        return Set(placed.map(\.id))
    }

    /// Best first, each place joins the first dot within `dotSpacing` of it, or starts its own. A
    /// dot sits at the middle of its places.
    static func cluster(_ ranked: [Candidate]) -> [Dot] {
        var groups: [[Candidate]] = []
        for candidate in ranked {
            if let index = groups.firstIndex(where: { distance($0[0], candidate) < dotSpacing }) {
                groups[index].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        return groups.map { group in
            let count = Double(group.count)
            return Dot(
                members: group.map(\.id),
                across: group.map(\.across).reduce(0, +) / count,
                down: group.map(\.down).reduce(0, +) / count
            )
        }
    }

    static func distance(_ a: Candidate, _ b: Candidate) -> Double {
        let dx = a.across - b.across
        let dy = a.down - b.down
        return (dx * dx + dy * dy).squareRoot()
    }

    static func isRankedBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        let left = a.score ?? -1
        let right = b.score ?? -1
        if left != right { return left > right }
        if a.dishCount != b.dishCount { return a.dishCount > b.dishCount }
        return a.id.uuidString < b.id.uuidString
    }
}

/// **The sheet's title** (Eamon, 25 Oct: no "dishes" in titles): **Near me**, or the suburb of a
/// Search here. Never "N dishes on the map", which stops being true the moment the map moves.
public enum DishMapTitle: Sendable, Equatable {
    case nearMe
    /// The suburb, once looked up; "This area" until then (or over water).
    case area(String?)

    public var text: String {
        switch self {
        case .nearMe: "Near me"
        case .area(let name): name ?? "This area"
        }
    }

    /// The one line when the list is empty.
    public var emptyLine: String {
        switch self {
        case .nearMe: "No dishes within \(Int(DishMapStore.nearRadius / 1000)) km"
        case .area: "No dishes here"
        }
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
