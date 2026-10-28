import Foundation
import Supabase

/// **Plate awards on the wire** (0098). There is no client write: the database earns an award from
/// the write that earns it. The app reads them, and says when the takeover has shown them.
public protocol AwardsReading: Sendable {
    /// `awards_of(p_user)` — a person's awards, newest first (yours when `userID` is nil). At most
    /// twenty, so unpaged. Empty through a block or for a deactivated profile.
    func awards(of userID: UUID?) async throws -> [EarnedAward]
    /// `mark_awards_seen(p_awards)` — the takeover has shown these (all of yours when nil).
    func markSeen(_ awards: [PlateAward]?) async throws
    /// `award_lines` — the dishes behind an opened award, oldest first, keyset on
    /// `(created_at, review_id)`.
    func lines(of userID: UUID?, award: PlateAward, after cursor: PageCursor?, limit: Int) async throws -> [AwardLine]
}

public struct AwardsClient: AwardsReading {
    /// `award_lines` clamps at 100.
    public static let maximumPageSize = 100

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func awards(of userID: UUID?) async throws -> [EarnedAward] {
        let data = try await api.supabase
            .rpc("awards_of", params: ["p_user": userID.map { AnyJSON.string($0.uuidString.lowercased()) } ?? .null])
            .execute()
            .data
        return try PostgRESTDate.decoder.decode(AwardRows.self, from: data).awards
    }

    public func markSeen(_ awards: [PlateAward]?) async throws {
        try await api.callRPC("mark_awards_seen", parameters: [
            "p_awards": awards.map { AnyJSON.array($0.map { .string($0.rawValue) }) } ?? .null
        ])
    }

    public func lines(
        of userID: UUID?, award: PlateAward, after cursor: PageCursor?, limit: Int
    ) async throws -> [AwardLine] {
        let data = try await api.supabase
            .rpc("award_lines", params: [
                "p_user": userID.map { AnyJSON.string($0.uuidString.lowercased()) } ?? .null,
                "p_award": .string(award.rawValue),
                "p_after_at": cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null,
                "p_after_id": cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null,
                "p_limit": .integer(min(Self.maximumPageSize, max(1, limit)))
            ])
            .execute()
            .data
        return try PostgRESTDate.decoder.decode([AwardLine].self, from: data)
    }
}

#if DEBUG
/// Awards in memory: previews, tests, `-ate-preview-data`. Debug only.
public final class InMemoryAwards: AwardsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [UUID?: [EarnedAward]]
    private let allLines: [PlateAward: [AwardLine]]
    public private(set) var markedSeen: [[PlateAward]?] = []

    /// `awards[nil]` are yours.
    public init(awards: [UUID?: [EarnedAward]] = [:], lines: [PlateAward: [AwardLine]] = [:]) {
        self.held = awards
        self.allLines = lines
    }

    public func awards(of userID: UUID?) async throws -> [EarnedAward] {
        lock.withLock { (held[userID] ?? []).sorted { $0.earnedAt > $1.earnedAt } }
    }

    public func markSeen(_ awards: [PlateAward]?) async throws {
        lock.withLock {
            markedSeen.append(awards)
            held[nil] = held[nil]?.map { a in
                guard a.seen == false, awards?.contains(a.award) ?? true else { return a }
                return EarnedAward(
                    award: a.award, earnedAt: a.earnedAt, entryID: a.entryID, dishID: a.dishID,
                    entryIDs: a.entryIDs, dishIDs: a.dishIDs, otherUserID: a.otherUserID,
                    otherHandle: a.otherHandle, seen: true, dishName: a.dishName,
                    restaurantName: a.restaurantName, score: a.score
                )
            }
        }
    }

    public func lines(
        of userID: UUID?, award: PlateAward, after cursor: PageCursor?, limit: Int
    ) async throws -> [AwardLine] {
        let all = allLines[award] ?? []
        let rest = cursor.map { after in
            all.filter { ($0.createdAt, $0.reviewID.uuidString) > (after.createdAt, after.id.uuidString) }
        } ?? all
        return Array(rest.prefix(limit))
    }
}
#endif
