import Foundation

/// **The rooms around the phone, read once and shared.**
///
/// The tab bar's + warms it, so by the time the Place key is tapped the sheet's Nearby section is
/// already in hand. It warms only where the location permission is already given: the ask itself
/// still belongs to the place sheet (``answer()``), the one moment the app has a use for it.
///
/// One read serves every sheet opened within ``freshFor`` from roughly the same spot, so a + that
/// is never followed by the Place key costs the read the sheet would have made anyway — never two.
@MainActor
public final class NearbyPlaces {
    /// Where the phone was and the rooms around it. `rooms` is empty when the read failed.
    public struct Answer: Sendable, Equatable {
        public let origin: SearchOrigin
        public let rooms: [PlaceSuggestion]

        public init(origin: SearchOrigin, rooms: [PlaceSuggestion]) {
            self.origin = origin
            self.rooms = rooms
        }
    }

    /// Where the phone is. `mayAsk` false answers `nil` rather than raise the permission alert.
    public typealias Locate = @MainActor (_ mayAsk: Bool) async -> SearchOrigin?

    /// How long one read stands in for the next.
    public static let freshFor: TimeInterval = 10 * 60
    /// How far the phone may have moved before the rooms are read again.
    public static let sameSpotMeters: Double = 150

    private let directory: any PlaceDirectory
    private let locate: Locate
    private let now: @Sendable () -> Date
    private var held: (answer: Answer, at: Date)?
    private var warming: Task<Answer?, Never>?

    public init(
        directory: any PlaceDirectory,
        locate: @escaping Locate,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.locate = locate
        self.now = now
    }

    /// Starts the read in the background, silently. Does nothing when one is already under way or
    /// the permission has not been given yet.
    public func warm() {
        guard warming == nil else { return }
        warming = Task { [weak self] in
            guard let self else { return nil }
            defer { self.warming = nil }
            guard let origin = await self.locate(false) else { return nil }
            return await self.rooms(at: origin)
        }
    }

    /// What the place sheet opens with: the warmed read when there is one, otherwise a fresh one —
    /// asking for the permission if it has never been asked. `nil` is no permission or no fix.
    public func answer() async -> Answer? {
        if let warming, let warmed = await warming.value { return warmed }
        guard let origin = await locate(true) else { return nil }
        return await rooms(at: origin)
    }

    private func rooms(at origin: SearchOrigin) async -> Answer {
        if let held, now().timeIntervalSince(held.at) < Self.freshFor,
           Self.meters(from: held.answer.origin, to: origin) < Self.sameSpotMeters {
            return held.answer
        }
        do {
            let rooms = try await directory.nearby(latitude: origin.latitude, longitude: origin.longitude)
            let answer = Answer(origin: origin, rooms: rooms)
            held = (answer, now())
            return answer
        } catch {
            // A failed read is not kept: the next sheet tries again.
            return Answer(origin: origin, rooms: [])
        }
    }

    /// Flat-earth distance — plenty for "has the phone moved a block".
    static func meters(from a: SearchOrigin, to b: SearchOrigin) -> Double {
        let metersPerDegree = 111_320.0
        let dLat = (b.latitude - a.latitude) * metersPerDegree
        let dLng = (b.longitude - a.longitude) * metersPerDegree * cos(a.latitude * .pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }
}
