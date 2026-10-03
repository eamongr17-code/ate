import Foundation
import Observation

/// **Where the feed is about** — the Feed's location pill, and the sheet behind it.
///
/// Near me, a city, or everywhere (``FeedLocation``). The choice is remembered **per person** on this
/// phone: two people sharing it keep their own feed, and signing out does not carry one person's
/// city into the next session. (The round-4 locality areas and `feed_areas()` were retired in round 8.)
@MainActor
@Observable
public final class FeedAreaModel {
    /// What the Feed is about. Near me until the person picks otherwise; remembered per person.
    public internal(set) var location: FeedLocation
    /// `feed_cities()`, busiest first — the picker, read ahead so its sheet rises full.
    @ObservationIgnored public let cityList: AteCityList
    public var cities: [AteCity] { cityList.cities }
    public var hasLoadedCities: Bool { cityList.hasLoaded }
    public func loadCitiesIfNeeded() async { await cityList.loadIfNeeded() }
    /// `resolve_city`'s answer for "near me". `nil` before it has answered, and when no city has
    /// food at all (then near me is everywhere).
    public private(set) var nearMe: AteCity?
    /// Whether near me has had a real answer (a city, or "no city has food") this session. A
    /// failed or cancelled read is not one: the next load asks again.
    public internal(set) var hasResolvedNearMe = false

    // Near me's machinery — `FeedArea+NearMe.swift`.
    /// Where the phone is, asked by the app (`nil`: refused, restricted or no fix). Unset, near me
    /// is answered without a point — the busiest city.
    public var locate: (@MainActor () async -> (latitude: Double, longitude: Double)?)?
    /// Near me moved after the feed was read — the app reloads it.
    public var onNearMeChanged: (@MainActor () -> Void)?
    /// The city the feed was last read with, so a later answer knows whether it changed anything.
    var servedCity: String??
    var resolving: Task<Void, Never>?

    // Where it opens — `FeedArea+Opening.swift`.
    /// Where the Feed opens for a person who has never picked: the rebuilt app's rule, their
    /// Journal's city (Eamon, 3 Oct). `nil` keeps near me, the current app's. Asked once, before the
    /// first read, and never remembered — only a pick is.
    @ObservationIgnored public var opening: (@MainActor () async -> FeedLocation)?
    /// The opening has been settled (applied, or not needed): what the control prints is real.
    public internal(set) var hasOpened = false
    var openingTask: Task<Void, Never>?

    private let reader: any EntryFeedReading
    private let store: any AteKeyValueStore
    private let owner: @Sendable () -> UUID?
    private let analytics: AnalyticsRecorder

    public init(
        reader: any EntryFeedReading,
        store: any AteKeyValueStore,
        owner: @escaping @Sendable () -> UUID?,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.reader = reader
        cityList = AteCityList { try await reader.feedCities() }
        self.store = store
        self.owner = owner
        self.analytics = analytics
        location = FeedLocation(stored: store.value(forKey: Self.locationKey(for: owner())))
    }

    /// Where a person's city choice is filed. Signed out has its own.
    public static func locationKey(for userID: UUID?) -> String {
        "ate.feedLocation.\(userID?.uuidString.lowercased() ?? "signedOut")"
    }

    /// The `p_city` every page is read with: the chosen city, near me's city, or `nil` (everywhere).
    public var city: String? {
        switch location {
        case .everywhere: nil
        case .city(let slug): slug
        case .nearMe: nearMe?.city
        }
    }

    /// Near me, and the phone really is in that city — the only time the control names a city
    /// beside "Near me".
    public var isNearMe: Bool { location == .nearMe && nearMe?.isNearby == true }

    /// Near me, not worked out yet — the control says "Near me" and nothing else, rather than a
    /// city (or Everywhere) it is about to take back.
    public var isResolvingNearMe: Bool { location == .nearMe && hasResolvedNearMe == false && nearMe == nil }

    /// What the control prints for where the feed is: a city's name, or "Everywhere".
    public var locationTitle: String {
        switch location {
        case .everywhere: return "Everywhere"
        case .city(let slug): return AteCity.displayName(for: slug, in: cities + [nearMe].compactMap { $0 })
        case .nearMe: return nearMe?.name ?? (hasResolvedNearMe ? "Everywhere" : "Near me")
        }
    }

    /// The picker's list, read afresh. Quietly keeps the last good one on a failure.
    public func loadCities() async { await cityList.load() }

    /// Works out near me from a point (`nil`: no permission, or no fix). Returns whether the city
    /// the Feed reads changed. Only a real answer counts — a row, or `[]` (no city has food, so near
    /// me is everywhere); a failure or a cancellation leaves near me as it was, unresolved, to be
    /// asked again.
    @discardableResult
    public func resolveNearMe(latitude: Double?, longitude: Double?) async -> Bool {
        let before = city
        let answer: AteCity?
        do {
            answer = try await reader.resolveCity(latitude: latitude, longitude: longitude)
        } catch {
            return false
        }
        nearMe = answer
        hasResolvedNearMe = true
        remember(answer)
        analytics(SocialEvents.feedNearMeResolved(
            hadLocation: latitude != nil, isNearby: answer?.isNearby == true, found: answer != nil
        ))
        return city != before
    }

    /// Stand-in for near me while the real answer is on its way: the last one this phone had, or
    /// the busiest city (`resolve_city` with no point). Never marks near me resolved.
    func fallBack() async {
        guard nearMe == nil, hasResolvedNearMe == false else { return }
        if let last = lastNearMe {
            nearMe = last
            return
        }
        let busiest = try? await reader.resolveCity(latitude: nil, longitude: nil)
        // The real answer may have landed while the busiest city was being asked for: it wins.
        guard nearMe == nil, hasResolvedNearMe == false, let busiest else { return }
        nearMe = busiest
    }

    private static let lastNearMeKey = "ate.feedNearMe.last"

    /// The last near me this phone was given — not a person's, the phone's.
    var lastNearMe: AteCity? {
        guard let stored = store.value(forKey: Self.lastNearMeKey) else { return nil }
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].isEmpty == false else { return nil }
        return AteCity(city: parts[0], name: parts[1], isNearby: parts[2] == "1")
    }

    private func remember(_ city: AteCity?) {
        store.setValue(city.map { "\($0.city)|\($0.name)|\($0.isNearby ? "1" : "0")" }, forKey: Self.lastNearMeKey)
    }

    /// Whether this person has picked where the Feed is about, on this phone.
    public var hasChosenLocation: Bool { store.value(forKey: Self.locationKey(for: owner())) != nil }

    /// Picks what the Feed is about. Returns whether the city it reads changed.
    @discardableResult
    public func choose(location next: FeedLocation) -> Bool {
        guard next != location else { return false }
        let before = city
        location = next
        store.setValue(next.stored, forKey: Self.locationKey(for: owner()))
        analytics(SocialEvents.feedLocationChanged(
            next,
            isNearby: next == .nearMe ? nearMe?.isNearby : nil,
            rank: { if case .city(let slug) = next { return cities.firstIndex { $0.city == slug } }; return nil }()
        ))
        return city != before
    }

    /// Re-reads the remembered choice — after a sign-in, when "whose phone is this" changed.
    public func reloadSelection() {
        location = FeedLocation(stored: store.value(forKey: Self.locationKey(for: owner())))
        openingTask = nil
        hasOpened = false
    }
}
