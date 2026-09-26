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
