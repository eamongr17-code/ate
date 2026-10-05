import Foundation

/// Where a photo was taken — `PHAsset.location`, reduced to two numbers.
public struct PhotoCoordinate: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres (haversine): good to well under a metre at these ranges.
    public func distance(to other: PhotoCoordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The cache key: four decimal places, about 11 m.
    public var rounded: PhotoCoordinate {
        PhotoCoordinate(
            latitude: (latitude * 10_000).rounded() / 10_000,
            longitude: (longitude * 10_000).rounded() / 10_000
        )
    }
}

/// **Nearby places on a photo sitting** — up to three places near where the photos were taken,
/// offered as chips. Nothing is attached by this type: a place reaches the composer only on a tap.
///
/// The asks are frugal by rule: one lookup at a time (`places-search?op=nearby`, through the place
/// directory), only for sittings on screen, each answer cached for the session by rounded coordinate,
/// and a sitting within ``sameSpot`` metres of one already asked reuses that answer instead of asking.
/// A failure is silent: no chips, and the sitting may ask again the next time it appears.
@MainActor
@Observable
public final class PhotoPlaceChips {
    public typealias Lookup = @Sendable (PhotoCoordinate) async throws -> [PlaceSuggestion]

    /// How many chips a sitting shows.
    public static let limit = 3
    /// Two sittings closer than this are the same room: the second never asks.
    public static let sameSpot: Double = 75

    /// The chips per sitting (cluster id). Absent = none (yet, or ever).
    public private(set) var chips: [String: [PlaceSuggestion]] = [:]

    @ObservationIgnored private let lookup: Lookup
    @ObservationIgnored private var answers: [PhotoCoordinate: [PlaceSuggestion]] = [:]
    @ObservationIgnored private var queue: [(id: String, coordinate: PhotoCoordinate)] = []
    @ObservationIgnored private var isDraining = false

    public init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    public func chips(for clusterID: String) -> [PlaceSuggestion] {
        chips[clusterID] ?? []
    }

    /// A sitting came on screen. With no location it never shows chips. Already answered (here or
    /// within ``sameSpot``): its chips at once. Otherwise it waits its turn; call ``drain()``.
    public func appeared(_ clusterID: String, at coordinate: PhotoCoordinate?) {
        guard let coordinate else { return }
        if let answer = answer(near: coordinate) {
            chips[clusterID] = answer
            return
        }
        guard queue.contains(where: { $0.id == clusterID }) == false else { return }
        queue.append((clusterID, coordinate))
    }

    /// A sitting left the screen before its turn: it is not asked about.
    public func disappeared(_ clusterID: String) {
        queue.removeAll { $0.id == clusterID }
    }

    /// Asks for the waiting sittings, one at a time, in the order they appeared. A second call while
    /// one is running returns at once — the running one picks up anything added meanwhile.
    public func drain() async {
        guard isDraining == false else { return }
        isDraining = true
        defer { isDraining = false }
        while queue.isEmpty == false {
            let next = queue.removeFirst()
            if let answer = answer(near: next.coordinate) {
                chips[next.id] = answer
                continue
            }
            guard let found = try? await lookup(next.coordinate.rounded) else { continue }
            let capped = Array(found.prefix(Self.limit))
            answers[next.coordinate.rounded] = capped
            chips[next.id] = capped
            // Anyone still waiting at the same spot has their answer now.
            for waiting in queue where waiting.coordinate.distance(to: next.coordinate) < Self.sameSpot {
                chips[waiting.id] = capped
            }
            queue.removeAll { $0.coordinate.distance(to: next.coordinate) < Self.sameSpot }
        }
    }

    private func answer(near coordinate: PhotoCoordinate) -> [PlaceSuggestion]? {
        if let exact = answers[coordinate.rounded] { return exact }
        return answers.first { $0.key.distance(to: coordinate) < Self.sameSpot }?.value
    }
}
