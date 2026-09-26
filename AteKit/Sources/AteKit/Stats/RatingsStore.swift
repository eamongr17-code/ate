import Foundation
import Observation

/// **Every dish you have scored, on one page** — grouped by score, highest first, under the chart.
///
/// A histogram bar no longer filters the list; it is a way *down* it. So the list is one stream of
/// groups, 5.0 first, and the groups are loaded **strictly in order**: a group appears only once
/// every group above it has been read to its end. That is the whole invariant, and it is what makes
/// "tap a bar, land on its group" honest — nothing above the group you jumped to can still grow and
/// shove it down the screen.
///
/// Still keyset-paged (ARCHITECTURE.md): `dishes_by_score` is asked one page at a time, per score.
/// A jump to a low bar walks the pages above it first — bounded by the person's own history, and a
/// page loop rather than one unbounded read.
///
/// The chart is fetched here rather than handed down from You, because the two screens fail
/// independently and a pushed page that inherits a stale chart disagrees with the one underneath.
@MainActor
@Observable
public final class RatingsStore {

    /// One score's rows.
    public struct Group: Sendable, Hashable, Identifiable {
        /// Always a half-step.
        public let score: Double
        /// The histogram's count of distinct dishes here — the "36 dishes" label. Not `dishes.count`:
        /// the rows are reviews, and the label counts dishes.
        public let dishCount: Int
        public internal(set) var dishes: [ScoredDish]
        /// Read to its end. Only then may the next group start.
        public internal(set) var isComplete: Bool

        public var id: Int { ScoreHistogram.halfSteps(score) }
    }

    /// The lit bar. The bar the page was opened on, and then the last one tapped.
    public private(set) var score: Double
    public private(set) var histogram = ScoreHistogram.empty
    /// The groups read so far, highest score first. A group with no rows is never in here.
    public private(set) var groups: [Group] = []
    public private(set) var isLoading = true
    /// A page failed. The list stops where it is; a pull to refresh starts it again.
    public private(set) var didFail = false

    private let stats: any StatsReading
    private let pageSize: Int
    private var viewer: UUID?
    private var hasLoaded = false
    /// The scores with something behind them, highest first — the order the page walks.
    private var order: [Double] = []
    /// Where the walk has got to: the index into ``order`` of the group being read, and the cursor
    /// for its next page (`nil` before its first page).
    private var position = 0
    private var cursor: PageCursor?
    /// The page in the air, if any. Everybody who wants the next page while one is loading waits on
    /// this one rather than giving up — a bar tapped mid-load still gets walked to its group.
    private var pageTask: Task<Void, Never>?
    /// Bumped by a refresh, so a page in the air for the old walk cannot land on the new one.
    private var generation = 0
    /// Bumped by every bar tap. Latest wins: a tap whose walk is overtaken by a newer tap stops
    /// walking, and reports that it is no longer the one on screen.
    private var selection = 0

    public init(score: Double, stats: any StatsReading, pageSize: Int = StatsClient.defaultDishLimit) {
        self.score = ScoreHistogram.snapped(score)
        self.stats = stats
        self.pageSize = pageSize
    }

    /// Every row on the page, in order — what the prefetch measures its distance against.
    public var dishes: [ScoredDish] { groups.flatMap(\.dishes) }

    /// True once every group has been read to its end.
    public var isExhausted: Bool { position >= order.count }

    public func group(at score: Double) -> Group? {
        let step = ScoreHistogram.halfSteps(score)
        return groups.first { $0.id == step }
    }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await load()
    }

    public func refresh() async {
        hasLoaded = false
        await load()
    }

    private func load() async {
        generation += 1
        let generationAtStart = generation
        isLoading = true
        defer { if generationAtStart == generation { isLoading = false } }
        guard let viewer = await viewerID() else { return }
        guard let chart = try? await stats.histogram(userID: viewer) else {
            guard generationAtStart == generation else { return }
            didFail = true
            return
        }
        guard generationAtStart == generation else { return }
        hasLoaded = true
        histogram = chart
        order = chart.buckets.filter { $0.dishCount > 0 }.map(\.score).sorted(by: >)
        groups = []
        position = 0
        cursor = nil
        didFail = false
        // The first screenful — and, when the page was opened on a bar, everything down to it.
        await reveal(score)
        if groups.isEmpty { await loadNextPage() }
    }

    /// The next page, asked for as the last few rows come into view.
    public func loadMoreIfNeeded(after dish: ScoredDish) async {
        let rows = dishes
        guard let index = rows.firstIndex(where: { $0.id == dish.id }),
              index >= rows.count - RatingsStore.prefetchDistance else { return }
        await loadNextPage()
    }

    /// How close to the end a row has to be before the next page is asked for.
    private static let prefetchDistance = 5

    /// A bar, tapped: light it, and read down the list until its group has rows on screen.
    ///
    /// **Returns whether this tap is still the one on screen** once its group is there — the view
    /// scrolls, and counts the view, only on `true`. Two quick taps: the first returns `false` (it
    /// was overtaken), the second `true`, so the page ends on the bar that is lit. A bar with
    /// nothing behind it is not a link, and returns `false`.
    @discardableResult
    public func select(_ next: Double) async -> Bool {
        let snapped = ScoreHistogram.snapped(next)
        guard histogram.dishCount(at: snapped) > 0 else { return false }
        selection += 1
        let mine = selection
        score = snapped
        await reveal(snapped, while: { self.selection == mine })
        return selection == mine && group(at: snapped) != nil
    }

    /// Reads pages in order until the group for `score` has started, or the list is exhausted, or a
    /// page fails. Every page it reads is one the person would have scrolled past anyway.
    ///
    /// `wanted` is asked before every page: a walk nobody is waiting for any more (its tap was
    /// overtaken) stops where it is.
    private func reveal(_ score: Double, while wanted: () -> Bool = { true }) async {
        let step = ScoreHistogram.halfSteps(score)
        guard order.contains(where: { ScoreHistogram.halfSteps($0) == step }) else { return }
        let generationAtStart = generation
        while group(at: score) == nil, isExhausted == false, didFail == false, wanted() {
            await loadNextPage()
            // A refresh started a new walk; that walk reveals for itself.
            guard generationAtStart == generation else { return }
        }
    }

    /// One page of the group being read, or the first page of the next one. While a page is in the
    /// air this waits for it instead — the caller's next look at the list sees that page landed.
    public func loadNextPage() async {
        if let pageTask {
            await pageTask.value
            return
        }
        guard isExhausted == false, didFail == false else { return }
        let task = Task { await fetchPage() }
        pageTask = task
        await task.value
    }

    private func fetchPage() async {
        defer { pageTask = nil }
        guard let viewer = await viewerID(), isExhausted == false, didFail == false else { return }
        let generationAtStart = generation
        let wanted = order[position]
        let after = cursor
        let page: Page<ScoredDish>
        do {
            page = try await stats.dishes(userID: viewer, score: wanted, after: after, pageSize: pageSize)
        } catch {
            guard generationAtStart == generation else { return }
            didFail = true
            return
        }
        guard generationAtStart == generation else { return }
        append(page, at: wanted)
    }

    private func append(_ page: Page<ScoredDish>, at wanted: Double) {
        // A keyset page can re-serve a row when one lands mid-scroll; the id is the guard.
        let known = Set(dishes.map(\.id))
        let fresh = page.items.filter { known.contains($0.id) == false }
        let step = ScoreHistogram.halfSteps(wanted)
        if let index = groups.firstIndex(where: { $0.id == step }) {
            groups[index].dishes.append(contentsOf: fresh)
        } else if fresh.isEmpty == false {
            groups.append(Group(
                score: wanted,
                dishCount: histogram.dishCount(at: wanted),
                dishes: fresh,
                isComplete: false
            ))
        }
        if let next = page.nextCursor {
            cursor = next
        } else {
            if let index = groups.firstIndex(where: { $0.id == step }) { groups[index].isComplete = true }
            position += 1
            cursor = nil
        }
    }

    private func viewerID() async -> UUID? {
        if let viewer { return viewer }
        viewer = try? await stats.viewerID()
        return viewer
    }
}

extension ScoredDish {
    /// **When it was scored**, as a Ratings row prints it: "19 Sep" this year, "19 Sep 2025" in any
    /// other. The order is the design's; the month's name is the reader's locale's.
    public func dateLabel(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let sameYear = calendar.component(.year, from: createdAt) == calendar.component(.year, from: now)
        let format: Date.FormatString = sameYear
            ? "\(day: .defaultDigits) \(month: .abbreviated)"
            : "\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)"
        return createdAt.formatted(Date.VerbatimFormatStyle(
            format: format, locale: locale, timeZone: calendar.timeZone, calendar: calendar
        ))
    }
}
