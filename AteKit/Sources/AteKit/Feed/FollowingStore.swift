import Foundation
import Observation

/// **One row of What you follow** — a followed category and its #1 dish in the city (the row's
/// thumb), `nil` until read or when it has none.
public struct FollowedCategory: Sendable, Hashable, Identifiable {
    public let craving: Craving
    public var top: FeedDish?

    public var id: String { craving.id }

    /// A stable id for the row's letter tile when it has no #1 dish: the category's own, folded into
    /// sixteen bytes, so the tile keeps its accent from launch to launch.
    public var tileID: UUID {
        top?.dishID ?? Self.fold(craving.id)
    }

    static func fold(_ key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in key.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public init(craving: Craving, top: FeedDish? = nil) {
        self.craving = craving
        self.top = top
    }
}

/// **What you follow** (4 Oct) — the one list of followed categories, reached from the end of the
/// Feed's edition: in shelf order (`my_cravings`), each with its #1 dish (`dishes_by_tag` row 1). A
/// swipe unfollows, a drag reorders; every change is one `set_cravings` with the whole ordered set,
/// shown at once and put back if it is refused. Changes are written one after another, so the last
/// one is the set that lands.
@MainActor
@Observable
public final class FollowingStore {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var rows: [FollowedCategory] = []

    @ObservationIgnored private let reads: any FeedEditionReading
    @ObservationIgnored private let city: String?
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var lastWrite: Task<Bool, Never>?

    public init(reads: any FeedEditionReading, city: String?, analytics: @escaping AnalyticsRecorder = { _ in }) {
        self.reads = reads
        self.city = city
        self.analytics = analytics
    }

    public var isEmpty: Bool { phase == .ready && rows.isEmpty }

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await refresh()
    }

    /// The set, then every thumb at once.
    public func refresh() async {
        hasLoaded = true
        guard let cravings = try? await reads.myCravings() else {
            if phase != .ready { phase = .failed(TagEditionStore.failureMessage) }
            return
        }
        let known = Dictionary(rows.map { ($0.id, $0.top) }, uniquingKeysWith: { first, _ in first })
        rows = cravings.map { FollowedCategory(craving: $0, top: known[$0.id].flatMap { $0 }) }
        phase = .ready
        let tops = await Self.readTops(cravings, reads: reads, city: city)
        rows = rows.map { row in
            var next = row
            if let top = tops[row.id] { next.top = top }
            return next
        }
    }

    /// A swipe's Unfollow.
    public func unfollow(_ id: String) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let before = rows
        rows.remove(at: index)
        let landed = await write(rows.map(\.craving))
        if landed == false { rows = before; return }
        analytics(FeedEvents.cravingUnfollowed(.following, count: rows.count))
    }

    /// A drag: the shelves follow the new order.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        let before = rows
        var next = rows
        next.move(fromOffsets: source, toOffset: destination)
        guard next != before else { return }
        rows = next
        let landed = await write(next.map(\.craving))
        if landed == false { rows = before; return }
        analytics(FeedEvents.cravingsReordered(count: rows.count))
    }

    /// One `set_cravings`, after any still in flight.
    private func write(_ cravings: [Craving]) async -> Bool {
        let previous = lastWrite
        let reads = reads
        let task = Task { @MainActor () -> Bool in
            _ = await previous?.value
            return (try? await reads.setCravings(cravings)) != nil
        }
        lastWrite = task
        return await task.value
    }

    private nonisolated static func readTops(
        _ cravings: [Craving], reads: any FeedEditionReading, city: String?
    ) async -> [String: FeedDish] {
        await withTaskGroup(of: (String, FeedDish?).self) { group in
            for craving in cravings {
                group.addTask {
                    (craving.id, try? await reads.cravingDishes(craving, city: city, limit: 1).first)
                }
            }
            var tops: [String: FeedDish] = [:]
            for await (id, top) in group {
                if let top { tops[id] = top }
            }
            return tops
        }
    }
}
