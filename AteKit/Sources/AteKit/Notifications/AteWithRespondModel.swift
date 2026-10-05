import Foundation

/// **Answering a tag** — the composer's prefilled face, as logic. The tagger's place and dishes are
/// read live (``AteWithResponding/prefill(companionID:)``); the person scores what they had, drops
/// what they did not, may add words, and posts THEIR OWN entry. One score slide steps through the
/// rows: letting go fills the row and moves to the next unscored one; it folds away once every row is
/// done. The tick is live from the start (the place is already attached).
@MainActor
@Observable
public final class AteWithRespondModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        /// Withdrawn, deleted, blocked, or declined: "This visit isn't here."
        case gone
        /// Already answered: their own entry, which is opened instead.
        case answered(UUID)
        /// The read did not land. The sheet keeps its skeleton and tries again.
        case unreachable
    }

    /// One of the tagger's dishes, as a row of the person's own entry.
    public struct Line: Identifiable, Equatable, Sendable {
        public let dishID: UUID
        public let name: String
        public var score: Rating?

        public var id: UUID { dishID }
    }

    public let companionID: UUID
    /// Minted once, so a retried post returns the same entry (`respond_ate_with`).
    public let entryID = UUID()
    public private(set) var phase: Phase = .loading
    public private(set) var prefill: AteWithPrefill?
    public private(set) var lines: [Line] = []
    public private(set) var removedCount = 0
    /// The row the slide is on. `nil`: the slide is folded away.
    public var current: UUID?
    public var body = ""
    public private(set) var isPosting = false

    @ObservationIgnored private let service: any AteWithResponding
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let maxPolls: Int

    public init(
        companionID: UUID,
        service: any AteWithResponding,
        analytics: @escaping AnalyticsRecorder = { _ in },
        pollInterval: Duration = .seconds(2),
        maxPolls: Int = 15
    ) {
        self.companionID = companionID
        self.service = service
        self.analytics = analytics
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    // MARK: - Reading the tag

    /// The prefill, read once on open — and again while the tagger's dishes are still on their way.
    public func load() async {
        for attempt in 0...maxPolls {
            if attempt > 0 {
                try? await Task.sleep(for: pollInterval)
                guard Task.isCancelled == false else { return }
            }
            do {
                let read = try await service.prefill(companionID: companionID)
                switch read.status {
                case .accepted:
                    phase = read.responseEntryID.map(Phase.answered) ?? .gone
                    return
                case .declined:
                    phase = .gone
                    return
                case .pending:
                    if read.isStillSorting { continue }
                    adopt(read)
                    return
                }
            } catch let error as AteWithError where error == .gone || error == .declined {
                phase = .gone
                return
            } catch {
                phase = .unreachable
                if attempt == maxPolls { return }
            }
        }
    }

    private func adopt(_ read: AteWithPrefill) {
        prefill = read
        lines = read.dishes.sorted { $0.position < $1.position }.map { Line(dishID: $0.dishID, name: $0.dishName) }
        current = lines.first?.id
        phase = .ready
    }

    // MARK: - Scoring

    /// A tap on a row: the slide goes back to it.
    public func select(_ dishID: UUID) {
        guard lines.contains(where: { $0.id == dishID }) else { return }
        current = dishID
    }

    /// The slide, mid-drag: the row's score follows the finger.
    public func slide(to rating: Rating) {
        guard let current, let index = lines.firstIndex(where: { $0.id == current }) else { return }
        lines[index].score = rating
    }

    /// Letting go: the row is filled and the slide moves to the next row still empty — after this one
    /// first, then from the top — or folds away when every row is done.
    public func finish(at rating: Rating) {
        guard let current, let index = lines.firstIndex(where: { $0.id == current }) else { return }
        lines[index].score = rating
        let after = lines[(index + 1)...].first { $0.score == nil }
        let before = lines[..<index].first { $0.score == nil }
        self.current = (after ?? before)?.id
    }

    /// The slide put away without a score.
    public func foldSlide() {
        current = nil
    }

    /// Swiped away: a dish they did not have. It leaves their entry, never the tagger's.
    public func remove(_ dishID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == dishID }) else { return }
        lines.remove(at: index)
        removedCount += 1
        if current == dishID {
            current = (lines[index...].first { $0.score == nil } ?? lines.first { $0.score == nil })?.id
        }
    }

    // MARK: - Posting

    private var hasWords: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

    /// Something to post — a dish or some words — and the tag in hand.
    public var canPost: Bool { phase == .ready && isPosting == false && (lines.isEmpty == false || hasWords) }

    /// The tick: posts the person's own entry. A tag that went away meanwhile moves the phase (and
    /// throws); anything else throws ``AteWithError/unreachable`` with everything kept for a retry.
    public func post() async throws -> EntryCard {
        guard canPost else { throw AteWithError.unreachable }
        isPosting = true
        defer { isPosting = false }
        let items = lines.map { AteWithItem(dishID: $0.dishID, score: $0.score) }
        do {
            let card = try await service.respond(
                companionID: companionID, entryID: entryID, items: items,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let scored = lines.filter { $0.score != nil }.count
            analytics(NotificationEvents.ateWithPosted(
                scored: scored, removed: removedCount, unscored: lines.count - scored, hasWords: hasWords
            ))
            return card
        } catch let error as AteWithError {
            switch error {
            case .gone, .declined, .alreadyAnswered: phase = .gone
            case .unreachable: break
            }
            throw error
        } catch {
            throw AteWithError.unreachable
        }
    }
}
