import Foundation
import Observation

/// One place on the Awards page: an award you hold, or the silhouette of one you don't (no name —
/// what it is stays hidden until it is earned).
public enum AwardCell: Sendable, Hashable, Identifiable {
    case earned(EarnedAward)
    case hidden(PlateAward)

    public var id: PlateAward {
        switch self {
        case .earned(let award): award.award
        case .hidden(let award): award
        }
    }
}

/// **A person's awards** — the band on You and on a profile, and the Awards page behind it.
///
/// One read (`awards_of`, at most twenty rows). Like every band under the header it degrades to
/// absent: a band that could not load is not drawn, and there is no "couldn't load" line.
@MainActor
@Observable
public final class AwardsStore {

    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case unavailable
    }

    /// Whose awards; nil = yours.
    public let userID: UUID?
    public private(set) var phase: Phase = .loading
    /// Newest first.
    public private(set) var earned: [EarnedAward] = []

    private let awards: any AwardsReading
    private var hasLoaded = false

    public init(userID: UUID?, awards: any AwardsReading) {
        self.userID = userID
        self.awards = awards
    }

    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        await load()
    }

    public func refresh() async {
        await load()
    }

    private func load() async {
        do {
            let rows = try await awards.awards(of: userID)
            hasLoaded = true
            earned = rows.sorted { ($0.earnedAt, $0.award.rawValue) > ($1.earnedAt, $1.award.rawValue) }
            phase = .ready
        } catch let error where error.isCancellation {
            return
        } catch {
            // not latched: the next appearance tries again
            if hasLoaded == false { phase = .unavailable }
        }
    }

    /// The Awards page: one grid, no groups. What you hold, newest first, then the silhouettes in
    /// the set's order — the secret 6 not at all until it is earned.
    public var cells: [AwardCell] {
        let held = Set(earned.map(\.award))
        return earned.map(AwardCell.earned)
            + PlateAward.allCases.filter { held.contains($0) == false && $0.isSecret == false }.map(AwardCell.hidden)
    }

    public func award(_ award: PlateAward) -> EarnedAward? {
        earned.first { $0.award == award }
    }

    /// "34 days after your first dish" — whole calendar days from the first dish to this one.
    public func daysAfterFirstDish(_ award: EarnedAward, calendar: Calendar = .current) -> Int? {
        guard award.award.milestone != nil, let first = self.award(.dishes1) else { return nil }
        return AwardsStore.days(from: first.earnedAt, to: award.earnedAt, calendar: calendar)
    }

    nonisolated static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: start)
        let b = calendar.startOfDay(for: end)
        return max(0, calendar.dateComponents([.day], from: a, to: b).day ?? 0)
    }
}

/// **The full-screen takeover's queue**: your unseen awards, all in one takeover, never one pop-up
/// each. Checked when a post's summary closes and when the app opens; the awards are marked seen
/// as the takeover comes up, so a takeover is never shown twice.
@MainActor
@Observable
public final class AwardTakeover {
    /// Non-empty while the takeover is up; newest first.
    public private(set) var showing: [EarnedAward] = []
    /// Every award you hold — the takeover's "N days after your first dish" reads the first dish's
    /// date from it.
    public private(set) var held: [EarnedAward] = []

    private let awards: any AwardsReading
    private var isChecking = false

    public init(awards: any AwardsReading) {
        self.awards = awards
    }

    /// Reads your awards; anything unseen comes up. A failure is silent — the next check catches up.
    public func check() async {
        guard showing.isEmpty, isChecking == false else { return }
        isChecking = true
        defer { isChecking = false }
        guard let rows = try? await awards.awards(of: nil) else { return }
        held = rows
        let unseen = rows.filter { $0.seen == false }
            .sorted { ($0.earnedAt, $0.award.rawValue) > ($1.earnedAt, $1.award.rawValue) }
        guard unseen.isEmpty == false else { return }
        showing = unseen
        try? await awards.markSeen(unseen.map(\.award))
    }

    public func finish() {
        showing = []
    }

    public func daysAfterFirstDish(_ award: EarnedAward, calendar: Calendar = .current) -> Int? {
        guard award.award.milestone != nil,
              let first = held.first(where: { $0.award == .dishes1 }) else { return nil }
        return AwardsStore.days(from: first.earnedAt, to: award.earnedAt, calendar: calendar)
    }
}

/// **The dishes behind an opened award** (`award_lines`), a page at a time, oldest first.
@MainActor
@Observable
public final class AwardLinesStore {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed
    }

    public static let pageSize = 60

    public private(set) var phase: Phase = .loading
    public private(set) var lines: [AwardLine] = []
    public private(set) var isExhausted = false

    private let userID: UUID?
    private let award: PlateAward
    private let awards: any AwardsReading
    private var isLoading = false

    public init(userID: UUID?, award: PlateAward, awards: any AwardsReading) {
        self.userID = userID
        self.award = award
        self.awards = awards
    }

    public func loadIfNeeded() async {
        guard lines.isEmpty, phase != .ready else { return }
        await page()
    }

    /// The next page, once the row `line` has appeared near the end.
    public func loadMore(after line: AwardLine) async {
        guard isExhausted == false, line.id == lines.last?.id else { return }
        await page()
    }

    private func page() async {
        guard isLoading == false else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await awards.lines(
                of: userID, award: award, after: lines.last?.cursor, limit: Self.pageSize
            )
            lines += next
            isExhausted = next.count < Self.pageSize
            phase = .ready
        } catch let error where error.isCancellation {
            return
        } catch {
            if lines.isEmpty { phase = .failed }
        }
    }
}
