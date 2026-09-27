import Foundation
import Observation

/// One row of `feed_areas()` (0038): an area — a place's locality, the label `p_area` filters on —
/// and how many entries the Feed holds there.
public struct FeedArea: Sendable, Hashable, Identifiable, Decodable {
    public let area: String
    public let count: Int

    public var id: String { area }

    public init(area: String, count: Int) {
        self.area = area
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case area, count
        case entryCount = "entry_count"
        case entries
    }

    /// `entry_count` is the contract's column; `count`/`entries` are tolerated so a rename on the
    /// server does not empty the sheet.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        area = try container.decode(String.self, forKey: .area)
        count = try container.decodeIfPresent(Int.self, forKey: .entryCount)
            ?? container.decodeIfPresent(Int.self, forKey: .count)
            ?? container.decodeIfPresent(Int.self, forKey: .entries)
            ?? 0
    }

    /// A page of areas: the sheet asks for this many, and the server clamps at 100.
    public static let pageSize = 30
    public static let maximumPageSize = 100

    public static func clampedLimit(_ limit: Int) -> Int {
        min(maximumPageSize, max(1, limit))
    }

    /// Whether `area` comes strictly after `cursor` in the keyset `(entry_count desc, area asc)`.
    public static func isAfter(_ area: FeedArea, cursor: FeedArea) -> Bool {
        area.count < cursor.count || (area.count == cursor.count && area.area > cursor.area)
    }

    /// Decodes the RPC's rows, drops blank areas, and puts them busiest first — ties by name, so
    /// the sheet never reshuffles between two opens. The server already sorts; this makes it true
    /// whatever the server does.
    public static func decodeList(_ data: Data) throws -> [FeedArea] {
        ordered(try JSONDecoder().decode([FeedArea].self, from: data))
    }

    public static func ordered(_ areas: [FeedArea]) -> [FeedArea] {
        var seen: Set<String> = []
        return areas
            .filter { $0.area.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .sorted { isAfter($1, cursor: $0) }
            .filter { seen.insert($0.area).inserted }
    }
}

/// **Where the feed is about** — the Feed's location pill, and the sheet behind it.
///
/// `nil` is everywhere. The choice is remembered **per person** on this phone: two people sharing
/// it keep their own feed, and signing out does not carry one person's city into the next session.
/// A remembered area that has since vanished from `feed_areas()` is still honoured — the reader
/// chose it, and an empty feed there is the truth, not a reason to quietly change their mind.
@MainActor
@Observable
public final class FeedAreaModel {
    public private(set) var areas: [FeedArea] = []
    public private(set) var selected: String?

    // MARK: Round 5 — the city (see ``FeedLocation``)

    /// What the Feed is about. Near me until the person picks otherwise; remembered per person.
    public private(set) var location: FeedLocation
    /// `feed_cities()`, busiest first — the picker.
    public private(set) var cities: [AteCity] = []
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
    public private(set) var isLoadingAreas = false
    public private(set) var hasReachedEnd = false

    private let reader: any EntryFeedReading
    private let store: any AteKeyValueStore
    private let owner: @Sendable () -> UUID?
    private let analytics: AnalyticsRecorder
    private let pageSize: Int
    private var generation = 0

    public init(
        reader: any EntryFeedReading,
        store: any AteKeyValueStore,
        owner: @escaping @Sendable () -> UUID?,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pageSize: Int = FeedArea.pageSize
    ) {
        self.pageSize = FeedArea.clampedLimit(pageSize)
        self.reader = reader
        self.store = store
        self.owner = owner
        self.analytics = analytics
        selected = store.value(forKey: Self.key(for: owner()))
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

    /// The picker's list. Quietly keeps the last good one on a failure.
    public func loadCities() async {
        guard let list = try? await reader.feedCities() else { return }
        cities = list
    }

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

    /// The key a person's choice is filed under. Signed out has its own.
    public static func key(for userID: UUID?) -> String {
        "ate.feedArea.\(userID?.uuidString.lowercased() ?? "signedOut")"
    }

    /// The sheet's first page, every time it opens — counts move. Quietly keeps the last good list
    /// on a failure: the sheet still offers Everywhere and the current choice, which is all a
    /// failure should leave.
    public func loadAreas() async {
        generation += 1
        let generationAtStart = generation
        isLoadingAreas = true
        defer { isLoadingAreas = false }
        guard let page = try? await reader.feedAreas(after: nil, limit: pageSize),
              generationAtStart == generation else { return }
        areas = FeedArea.ordered(page)
        hasReachedEnd = page.count < pageSize
    }

    /// Called as a row appears: the next page once the last few are on screen.
    public func loadMoreAreasIfNeeded(after area: FeedArea) async {
        guard let index = areas.firstIndex(of: area), index >= areas.count - 5 else { return }
        await loadMoreAreas()
    }

    public func loadMoreAreas() async {
        guard isLoadingAreas == false, hasReachedEnd == false, let cursor = areas.last else { return }
        let generationAtStart = generation
        isLoadingAreas = true
        defer { isLoadingAreas = false }
        guard let page = try? await reader.feedAreas(after: cursor, limit: pageSize),
              generationAtStart == generation else { return }
        // Dedup on arrival: a count that moved between pages can offer an area twice.
        let known = Set(areas.map(\.area))
        areas += FeedArea.ordered(page.filter { known.contains($0.area) == false })
        hasReachedEnd = page.count < pageSize
    }

    /// Re-reads the remembered choice — after a sign-in, when "whose phone is this" changed.
    public func reloadSelection() {
        selected = store.value(forKey: Self.key(for: owner()))
        location = FeedLocation(stored: store.value(forKey: Self.locationKey(for: owner())))
    }

    /// Picks an area (`nil` = everywhere). Returns whether anything changed, so the caller reloads
    /// the feed only when it has something new to show.
    @discardableResult
    public func choose(_ area: String?) -> Bool {
        guard area != selected else { return false }
        selected = area
        store.setValue(area, forKey: Self.key(for: owner()))
        analytics(SocialEvents.feedAreaChanged(
            area: area,
            rank: area.flatMap { name in areas.firstIndex { $0.area == name } }
        ))
        return true
    }
}
