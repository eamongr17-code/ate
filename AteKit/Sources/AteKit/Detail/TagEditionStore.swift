import Foundation
import Observation

/// **A place known for a category** — one card of a category page's "Places known for it": the place,
/// and its best dish carrying the tag (the first of its rows in `dishes_by_tag`'s own order).
public struct TagPlace: Sendable, Hashable, Identifiable {
    public let restaurantID: UUID
    public var dish: FeedDish

    public var id: UUID { restaurantID }
    /// A display string.
    public var restaurantName: String { dish.restaurantName }

    public init(restaurantID: UUID, dish: FeedDish) {
        self.restaurantID = restaurantID
        self.dish = dish
    }
}

/// **A category page's rules** (`design/rebuild/discover.html`, approved 4 Oct), stated once so the
/// tests hold them.
public enum TagEdition {
    /// The hero and ranked rows 2 to 8: `dishes_by_tag` rows 1 to 8 as returned.
    public static let rankedCount = 8
    /// The one `dishes_by_tag` read the page makes; the places shelf is grouped from it.
    public static let readLimit = 50
    public static let placesLimit = 10
    public static let newLimit = FeedEditionStore.newLimit
    /// Five receipts at most, then the end line. The page is finite.
    public static let receiptsCap = FeedEditionStore.latestCap
    /// "New in <tag>" looks back this far — the Feed's own first look back.
    public static let newLookBack: TimeInterval = 7 * 24 * 60 * 60

    /// One card per place, in the order the dishes came: the first row per place is its best dish in
    /// the category. A row with no place is left out.
    public static func places(from dishes: [FeedDish], limit: Int = placesLimit) -> [TagPlace] {
        var seen: Set<UUID> = []
        return dishes.compactMap { dish -> TagPlace? in
            guard let place = dish.restaurantID, seen.insert(place).inserted else { return nil }
            return TagPlace(restaurantID: place, dish: dish)
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// "New in curry" — a dish style read mid-sentence (lowered), a cuisine as its own name
    /// ("New in Vietnamese").
    public static func newTitle(_ tag: DishTagRoute) -> String {
        let name = tag.kind == .style ? LovedShelf.midSentence(tag.label) : tag.label
        return "New in \(name)"
    }
}

/// **A category's own page, as an edition** (4 Oct): the #1 dish as the hero, 2 to 8 as ranked rows,
/// the places known for it, what is new in it, its latest receipts, and the Follow toggle.
///
/// One `dishes_by_tag` read (50 rows) feeds the hero, the ranks and the places. "New in" and the
/// receipts are their own reads and stand alone: one that fails or answers nothing is not on the page
/// (no error line for a missing section). Only the dishes read decides the page's own state.
@MainActor
@Observable
public final class TagEditionStore: SavedDishObserving {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    public static let failureMessage = "Couldn't\nreach Ate."

    public let tag: DishTagRoute
    public private(set) var phase: Phase = .loading
    public private(set) var dishes: [FeedDish] = []
    public private(set) var newDishes: [NewDish] = []
    public private(set) var receipts: [EntryCard] = []
    /// Whether the viewer follows this category. Always `false` signed out.
    public private(set) var isFollowing = false

    @ObservationIgnored private let reads: any FeedEditionReading
    @ObservationIgnored private let isSignedIn: @MainActor () -> Bool
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var followTaps = 0

    public init(
        tag: DishTagRoute,
        reads: any FeedEditionReading,
        isSignedIn: @escaping @MainActor () -> Bool,
        analytics: @escaping AnalyticsRecorder = { _ in },
        savedDishes: SavedDishBroadcast? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tag = tag
        self.reads = reads
        self.isSignedIn = isSignedIn
        self.analytics = analytics
        self.now = now
        savedDishes?.add(self)
    }

    private var craving: Craving { Craving(tag) }

    // MARK: - What the page shows

    /// The hero (row 1) and the ranked rows (2 to 8).
    public var top: [FeedDish] { Array(dishes.prefix(TagEdition.rankedCount)) }
    /// More than eight: a "See all" row opens the plain ranked list.
    public var hasMore: Bool { dishes.count > TagEdition.rankedCount }
    public var places: [TagPlace] { TagEdition.places(from: dishes) }
    public var newTitle: String { TagEdition.newTitle(tag) }
    /// The city under the title: the one the page is read in, or everywhere. A place's own tag (a
    /// suburb, a city) carries none: the title already says where, and "Northcote Everywhere" reads
    /// as nonsense (Eamon, 6 Oct).
    public var cityTitle: String? {
        switch tag.kind {
        case .suburb, .city: nil
        default: tag.city.map { AteCity.displayName(for: $0) } ?? "Everywhere"
        }
    }

    // MARK: - Reading

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    /// Everything at once. A refresh that fails keeps what is on screen.
    public func refresh() async {
        hasLoaded = true
        let reads = reads
        let craving = craving
        let city = tag.city
        let since = now().addingTimeInterval(-TagEdition.newLookBack)
        let signedIn = isSignedIn()
        async let rows = Self.attempt {
            try await reads.cravingDishes(craving, city: city, limit: TagEdition.readLimit)
        }
        async let fresh = Self.attempt {
            try await reads.newToRecord(tag: craving, city: city, since: since, limit: TagEdition.newLimit)
        }
        async let latest = Self.attempt {
            try await reads.latestReceipts(tag: craving, city: city, limit: TagEdition.receiptsCap)
        }
        async let follows = signedIn ? Self.attempt { try await reads.myCravings() } : nil
        let answers = await (rows: rows, fresh: fresh, latest: latest, follows: follows)

        if let rows = answers.rows {
            dishes = rows
            phase = rows.isEmpty ? .empty : .ready
        } else if phase != .ready {
            phase = .failed(Self.failureMessage)
        }
        if let fresh = answers.fresh { newDishes = fresh } else if phase != .ready { newDishes = [] }
        if let latest = answers.latest {
            receipts = Array(latest.prefix(TagEdition.receiptsCap))
        } else if phase != .ready {
            receipts = []
        }
        if let follows = answers.follows {
            isFollowing = follows.contains { $0.id == craving.id }
        } else if signedIn == false {
            isFollowing = false
        }
    }

    // MARK: - Follow

    /// The glass Follow / Following: flips at once, then adds this category to the set (or takes it
    /// out) with `set_cravings`, read fresh first so a set changed elsewhere is not overwritten.
    /// A refusal puts it back. The caller asks the gate first; signed out it is never called.
    public func toggleFollow() async {
        let previous = lastWrite
        let wantsFollow = isFollowing == false
        isFollowing = wantsFollow
        followTaps += 1
        let tap = followTaps
        let write = Task { @MainActor [weak self] in
            await previous?.value
            await self?.write(follow: wantsFollow, tap: tap)
        }
        lastWrite = write
        await write.value
    }

    /// Only the newest tap's answer is drawn; an older one landing does not flip it back.
    private func write(follow: Bool, tap: Int) async {
        let craving = craving
        do {
            let current = try await reads.myCravings()
            var next = current.filter { $0.id != craving.id }
            if follow { next.append(craving) }
            let answer = try await reads.setCravings(next)
            let following = answer.contains { $0.id == craving.id }
            if tap == followTaps { isFollowing = following }
            analytics(following
                ? FeedEvents.cravingFollowed(.tagPage, count: answer.count)
                : FeedEvents.cravingUnfollowed(.tagPage, count: answer.count))
        } catch {
            if tap == followTaps { isFollowing = follow == false }
        }
    }

    // MARK: - Saves

    public func savedDishChanged(dishID: UUID, isSaved: Bool) {
        func flip(_ dish: FeedDish) -> FeedDish {
            guard dish.dishID == dishID else { return dish }
            var next = dish
            next.isSaved = isSaved
            return next
        }
        dishes = dishes.map(flip)
        newDishes = newDishes.map { NewDish(kind: $0.kind, dish: flip($0.dish), at: $0.at) }
        receipts = receipts.map { $0.settingSaved(dishID: dishID, to: isSaved) }
    }

    /// An entry deleted elsewhere leaves the receipts.
    public func removeEntry(_ entryID: UUID) {
        receipts.removeAll { $0.id == entryID }
    }

    private nonisolated static func attempt<Value: Sendable>(
        _ read: @Sendable () async throws -> Value
    ) async -> Value? {
        try? await read()
    }
}
