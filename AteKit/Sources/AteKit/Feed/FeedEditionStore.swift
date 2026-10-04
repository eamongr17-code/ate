import Foundation
import Observation

/// **The Feed as an edition** (round 8) — a finite page you finish: The Top Ate, Because you loved…,
/// New to the record, a shelf per craving, the cravings row, a short run of the latest receipts (the
/// feed's own ``EntryListStore``), then "You're caught up".
///
/// The sections are read together and each stands alone: a section with no rows is not on the page,
/// and one whose read falls over is simply absent (a refresh that fails keeps what is on screen). No
/// error line for a missing section — an absent shelf is not something to explain (design rule 1).
///
/// Signed out, only The Top Ate (and the latest receipts) are read; the personal sections — Because
/// you loved, New to the record, the cravings — are not asked for and not shown.
///
/// Every row carries the viewer's bookmark, and it listens to ``SavedDishBroadcast`` like every other
/// list that draws one, so a save made anywhere is already true here.
@MainActor
@Observable
public final class FeedEditionStore: SavedDishObserving {
    // The contract's limits.
    public nonisolated static let topAteLimit = 8
    public nonisolated static let lovedLimit = 10
    public nonisolated static let newLimit = 6
    public nonisolated static let shelfLimit = 10
    /// The latest receipts are a short run, not the feed: this many, and no paging.
    public nonisolated static let latestCap = 5
    /// New to the record's first look back, when this phone has never opened the Feed for this person.
    public static let firstLookBack: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var topAte: [TopAteLine] = []
    public private(set) var loved: LovedShelf?
    public private(set) var newDishes: [NewDish] = []
    /// The followed cravings, in the order they were chosen.
    public private(set) var cravings: [Craving] = []
    /// One per craving that has dishes, in the cravings' order.
    public private(set) var shelves: [CravingShelf] = []
    /// The first read has answered. Until then the page is The Top Ate's skeleton.
    public private(set) var isSettled = false
    /// Whether the last read was made signed in — what decides the personal sections.
    public private(set) var isPersonal = false
    /// The city the edition was last read in — a shelf's See all opens its tag page there.
    public private(set) var city: String?

    /// The picker's chips, read when it is first opened.
    public private(set) var options: [CravingOption] = []
    public private(set) var hasLoadedOptions = false

    /// "What do you crave?" (4 Oct) — the card after The Top Ate, asked once: its pills (the first
    /// six of `craving_options()`, busiest first), what has been picked on it, and whether it stands.
    public private(set) var askOptions: [CravingOption] = []
    public private(set) var askPicks: [Craving] = []
    public private(set) var isAsking = false
    /// At most this many pills on the card…
    public nonisolated static let askOptionLimit = 6
    /// …and this many picks fold it.
    public nonisolated static let askPickLimit = 3

    @ObservationIgnored private let reads: any FeedEditionReading
    @ObservationIgnored private let store: any AteKeyValueStore
    @ObservationIgnored private let owner: @Sendable () -> UUID?
    @ObservationIgnored private let isSignedIn: @MainActor () -> Bool
    @ObservationIgnored private let cityForRead: @MainActor () async -> String?
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let now: @Sendable () -> Date
    /// New to the record's `p_since`, fixed for the life of this store: a refresh keeps asking about
    /// the same "since you last looked", and the next session asks from this one.
    @ObservationIgnored private var since: Date?
    @ObservationIgnored private var sinceOwner: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var viewed: Set<FeedEvents.Section> = []
    @ObservationIgnored private let preferences: AtePreferences?
    @ObservationIgnored private var hasRecordedAsk = false
    /// Card picks are written one after another, so the last tap is the set that lands.
    @ObservationIgnored private var lastWrite: Task<Bool, Never>?

    public init(
        reads: any FeedEditionReading,
        store: any AteKeyValueStore,
        owner: @escaping @Sendable () -> UUID?,
        isSignedIn: @escaping @MainActor () -> Bool,
        city: @escaping @MainActor () async -> String?,
        analytics: @escaping AnalyticsRecorder = { _ in },
        savedDishes: SavedDishBroadcast? = nil,
        preferences: AtePreferences? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.reads = reads
        self.store = store
        self.owner = owner
        self.isSignedIn = isSignedIn
        self.cityForRead = city
        self.analytics = analytics
        self.now = now
        savedDishes?.add(self)
    }

    // MARK: - What the page shows

    public var showsTopAte: Bool { topAte.isEmpty == false }
    public var showsLoved: Bool { isPersonal && (loved?.dishes.isEmpty == false) }
    public var showsNew: Bool { isPersonal && newDishes.isEmpty == false }
    public var visibleShelves: [CravingShelf] { isPersonal ? shelves.filter { $0.dishes.isEmpty == false } : [] }
    /// The row that opens the picker: signed in, once the page has been read.
    public var showsChooseCravings: Bool { isPersonal && isSettled }
    /// The ask card: signed in, standing, with pills to show.
    public var showsAsk: Bool { isPersonal && isAsking && askOptions.isEmpty == false }
    /// The What you follow row at the end of the edition — only when something is followed.
    public var showsFollowing: Bool { isPersonal && isSettled && cravings.isEmpty == false }
    /// Nothing above the latest receipts at all.
    public var isEmpty: Bool {
        showsTopAte == false && showsLoved == false && showsNew == false && visibleShelves.isEmpty
    }

    // MARK: - Reading

    private var hasLoaded = false

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    /// A pull to refresh, a sign-in: read everything again, keeping what is on screen until it lands.
    public func refresh() async {
        hasLoaded = true
        generation += 1
        let generationAtStart = generation
        let personal = isSignedIn()
        let city = await cityForRead()
        let since = personal ? sinceForThisSession() : nil
        let wantsAsk = personal && isAsking == false && preferences?.hasAnsweredCravingsAsk(owner()) == false
        let answers = await Self.read(reads, city: city, since: since, wantsAsk: wantsAsk)

        guard generationAtStart == generation, Task.isCancelled == false else { return }
        self.city = city
        isPersonal = personal
        if let rows = answers.top { topAte = rows } else if isSettled == false { topAte = [] }
        if personal {
            if let shelf = answers.loved { loved = shelf } else if isSettled == false { loved = nil }
            if let rows = answers.fresh { newDishes = rows } else if isSettled == false { newDishes = [] }
            if let read = answers.cravings {
                cravings = read.cravings
                shelves = read.shelves
                // First time only: somebody who follows nothing and has never answered.
                if wantsAsk, read.cravings.isEmpty, let options = answers.askOptions, options.isEmpty == false {
                    askOptions = Array(options.prefix(Self.askOptionLimit))
                    askPicks = []
                    isAsking = true
                }
            }
        } else {
            loved = nil
            newDishes = []
            cravings = []
            shelves = []
            isAsking = false
        }
        isSettled = true
    }

    /// The city changed: start again from nothing, so the old city's rows never stand in for the new.
    public func reload() async {
        generation += 1
        topAte = []
        loved = nil
        newDishes = []
        shelves = []
        isSettled = false
        viewed = []
        await refresh()
    }

    // MARK: - Cravings

    public func loadOptionsIfNeeded() async {
        guard hasLoadedOptions == false else { return }
        guard let answer = try? await reads.cravingOptions() else { return }
        options = answer
        hasLoadedOptions = true
    }

    /// The picker's Done: the whole set replaces the last one (`set_cravings`), and the shelves are
    /// read again for it. Returns whether it landed; a refusal leaves the set as it was.
    @discardableResult
    public func saveCravings(_ chosen: [Craving]) async -> Bool {
        let next: [Craving]
        do {
            // The server's answer is the set: duplicates collapsed, capped.
            next = try await reads.setCravings(chosen)
        } catch {
            return false
        }
        analytics(FeedEvents.cravingsSet(count: next.count))
        cravings = next
        // Shelves for cravings still followed stay up while the new set is read.
        let kept = Set(next.map(\.id))
        shelves = shelves.filter { kept.contains($0.id) }
        let shelves = await Self.readShelves(for: next, reads: reads, city: city)
        guard cravings == next else { return true }
        self.shelves = shelves
        return true
    }

    /// The Feed came back on screen: a category may have been followed or unfollowed on its own
    /// page, or in What you follow. Read the set again and, if it moved, its shelves.
    public func refreshCravings() async {
        guard isSettled, isPersonal, isSignedIn() else { return }
        guard let read = try? await reads.myCravings(), read != cravings else { return }
        cravings = read
        let kept = Set(read.map(\.id))
        shelves = shelves.filter { kept.contains($0.id) }
        let fresh = await Self.readShelves(for: read, reads: reads, city: city)
        guard cravings == read else { return }
        shelves = fresh
    }

    // MARK: - Asked once

    /// A pill on the card: it follows (or, tapped again, unfollows) that category at once. The first
    /// tap answers the card for good; the third pick folds it.
    public func pickFromAsk(_ option: CravingOption) async {
        guard isAsking else { return }
        let craving = option.craving
        let wasPicked = askPicks.contains { $0.id == craving.id }
        if wasPicked {
            askPicks.removeAll { $0.id == craving.id }
        } else {
            askPicks.append(craving)
        }
        preferences?.answeredCravingsAsk(owner())
        let folds = askPicks.count >= Self.askPickLimit
        if folds { isAsking = false }
        let landed = await writeAskPicks()
        guard landed else {
            // Refused: the pill goes back to how the server has it, and the card stands again.
            if wasPicked { askPicks.append(craving) } else { askPicks.removeAll { $0.id == craving.id } }
            if folds { isAsking = true }
            return
        }
        if wasPicked {
            analytics(FeedEvents.cravingUnfollowed(.ask, count: cravings.count))
        } else {
            analytics(FeedEvents.cravingFollowed(.ask, count: cravings.count))
            analytics(FeedEvents.cravingsAskPicked(pick: askPicks.count))
        }
    }

    /// The card's close: it folds, for good.
    public func dismissAsk() {
        guard isAsking else { return }
        isAsking = false
        preferences?.answeredCravingsAsk(owner())
        analytics(FeedEvents.cravingsAskDismissed(picks: askPicks.count))
    }

    /// The card came on screen — `cravings_ask_shown`, once.
    public func askAppeared() {
        guard hasRecordedAsk == false, showsAsk else { return }
        hasRecordedAsk = true
        analytics(FeedEvents.cravingsAskShown(options: askOptions.count))
    }

    /// The set the card stands for — whatever else is followed, then its picks in the order made —
    /// written after any write still in flight, and read when its turn comes.
    private func writeAskPicks() async -> Bool {
        let previous = lastWrite
        let write = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            let onCard = Set(self.askOptions.map(\.id))
            let desired = self.cravings.filter { onCard.contains($0.id) == false } + self.askPicks
            return await self.saveCravings(desired)
        }
        lastWrite = write
        return await write.value
    }

    // MARK: - Saves

    public func savedDishChanged(dishID: UUID, isSaved: Bool) {
        func flip(_ dish: FeedDish) -> FeedDish {
            guard dish.dishID == dishID else { return dish }
            var next = dish
            next.isSaved = isSaved
            return next
        }
        topAte = topAte.map { TopAteLine(rank: $0.rank, dish: flip($0.dish)) }
        if var shelf = loved {
            shelf.dishes = shelf.dishes.map(flip)
            loved = shelf
        }
        newDishes = newDishes.map { NewDish(kind: $0.kind, dish: flip($0.dish), at: $0.at) }
        shelves = shelves.map { CravingShelf(craving: $0.craving, dishes: $0.dishes.map(flip)) }
    }

    // MARK: - Telemetry

    /// The Feed came on screen: every section counts as unseen again.
    public func beginVisit() {
        viewed = []
    }

    /// A section came on screen — `feed_section_viewed`, once per section per visit.
    public func sectionAppeared(_ section: FeedEvents.Section) {
        guard viewed.insert(section).inserted else { return }
        analytics(FeedEvents.sectionViewed(section))
    }

    // MARK: - Since you last looked

    /// Where a person's last open of the Feed is filed on this phone.
    public static func lastOpenedKey(for userID: UUID?) -> String {
        "ate.feedLastOpened.\(userID?.uuidString.lowercased() ?? "signedOut")"
    }

    /// The last open, read once per person per store; this open is written down as the next one's.
    private func sinceForThisSession() -> Date {
        let person = owner()
        if let since, sinceOwner == person { return since }
        let key = Self.lastOpenedKey(for: person)
        let current = now()
        let stored = store.value(forKey: key).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let answer = stored ?? current.addingTimeInterval(-Self.firstLookBack)
        store.setValue(String(current.timeIntervalSince1970), forKey: key)
        since = answer
        sinceOwner = person
        return answer
    }

    // MARK: - Machinery

    private nonisolated static func attempt<Value: Sendable>(
        _ read: @Sendable () async throws -> Value
    ) async -> Value? {
        try? await read()
    }

    private struct CravingsRead: Sendable {
        let cravings: [Craving]
        let shelves: [CravingShelf]
    }

    /// Every section's answer — `nil` where the read failed (or, signed out, was not made). A loved
    /// shelf is doubly optional: read and absent is not the same as not read.
    private struct Answers: Sendable {
        var top: [TopAteLine]?
        var loved: LovedShelf??
        var fresh: [NewDish]?
        var cravings: CravingsRead?
        var askOptions: [CravingOption]?
    }

    /// All the sections at once. `since` is `nil` signed out, and then only The Top Ate is read.
    private nonisolated static func read(
        _ reads: any FeedEditionReading,
        city: String?,
        since: Date?,
        wantsAsk: Bool = false
    ) async -> Answers {
        async let top = attempt { try await reads.topAte(city: city, limit: topAteLimit) }
        guard let since else { return Answers(top: await top) }
        async let loved = attempt { try await reads.becauseYouLoved(city: city, limit: lovedLimit) }
        async let fresh = attempt { try await reads.newToRecord(city: city, since: since, limit: newLimit) }
        async let cravings = readCravings(reads, city: city)
        async let options = wantsAsk ? attempt { try await reads.cravingOptions() } : nil
        return await Answers(top: top, loved: loved, fresh: fresh, cravings: cravings, askOptions: options)
    }

    private nonisolated static func readCravings(
        _ reads: any FeedEditionReading, city: String?
    ) async -> CravingsRead? {
        guard let cravings = try? await reads.myCravings() else { return nil }
        return CravingsRead(cravings: cravings, shelves: await readShelves(for: cravings, reads: reads, city: city))
    }

    /// Every shelf at once, laid back in the cravings' order. A shelf whose read failed is left out.
    private nonisolated static func readShelves(
        for cravings: [Craving],
        reads: any FeedEditionReading,
        city: String?
    ) async -> [CravingShelf] {
        let answers = await withTaskGroup(of: (Int, [FeedDish]?).self) { group in
            for (index, craving) in cravings.enumerated() {
                group.addTask {
                    (index, try? await reads.cravingDishes(craving, city: city, limit: shelfLimit))
                }
            }
            var collected: [Int: [FeedDish]] = [:]
            for await (index, rows) in group {
                if let rows { collected[index] = rows }
            }
            return collected
        }
        return cravings.enumerated().compactMap { index, craving in
            answers[index].map { CravingShelf(craving: craving, dishes: $0) }
        }
    }
}

// MARK: - The picker

/// **The cravings picker's draft** — the options in their groups and what is ticked. Nothing is saved
/// until Done; the selection keeps the order the cravings were first chosen in, new ones last.
public struct CravingPicker: Sendable, Equatable {
    /// `set_cravings` keeps at most this many (0055): past it, another chip does not tick.
    public static let maximum = 24

    public private(set) var selection: [Craving]
    public let options: [CravingOption]

    public init(options: [CravingOption], selected: [Craving]) {
        self.options = options
        self.selection = selected
    }

    /// The groups that have chips, in print order: dishes, cuisines, moods.
    public var groups: [(group: CravingOption.Group, options: [CravingOption])] {
        CravingOption.Group.allCases.compactMap { group in
            let chips = options.filter { $0.group == group }
            return chips.isEmpty ? nil : (group, chips)
        }
    }

    public func isOn(_ option: CravingOption) -> Bool {
        selection.contains { $0.id == option.id }
    }

    public mutating func toggle(_ option: CravingOption) {
        if let index = selection.firstIndex(where: { $0.id == option.id }) {
            selection.remove(at: index)
        } else if selection.count < Self.maximum {
            selection.append(option.craving)
        }
    }
}
