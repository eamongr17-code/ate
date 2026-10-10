import Foundation
import Observation

/// **The Summary after Done** (`SummaryLoading` → `SummaryFinal`, 2026-09-26): the entry's receipt as
/// the hero on the coral ground, printing while the sorter works.
///
/// What is known prints at once — the place, the photos, the order number, the date — and the lines
/// still being sorted are skeleton bars. This store is the watching half: it holds the row, asks for
/// it again until the sorter has answered, and says which state the receipt is in. The app asked for
/// the sort itself when the entry was saved, so this watches rather than drives, and it gives up
/// rather than hammering.
///
/// **An empty receipt is never printed or shared.** A placeless entry sorts to no lines (the plan is
/// parked until a place is attached), so "sorted" alone is not "printed": the receipt prints only
/// with a place and at least one line.
@MainActor
@Observable
public final class EntrySummaryStore {
    public enum Phase: Sendable, Equatable {
        /// The words are saved; the lines are not back yet. The skeleton breathes.
        case sorting
        /// The receipt has printed — Share is live.
        case printed
        /// Sorted, but nothing can print until a place is attached: the receipt's place slot is
        /// the Place key.
        case needsPlace
        /// The sorter failed, found nothing to print, or took longer than anyone waits on this
        /// screen. The skeleton stops breathing and the ink pill offers "Print it again".
        case stalled
    }

    /// What the store needs from the entry service — closures, so the Summary can be driven by a
    /// debug stand-in as easily as by the real thing.
    public struct Actions: Sendable {
        public var fetch: @Sendable (UUID) async throws -> EntryCard
        /// `correct_entry_place`: attaches the place and prints the parked plan.
        public var correctPlace: @Sendable (_ entryID: UUID, _ restaurantID: UUID) async throws -> EntryCard
        /// A forced re-sort, carrying the composer's tag chips again.
        public var resort: @Sendable (UUID) async throws -> Void
        /// `correct_entry_dish`: a line re-named — a dish the place has (its id) or a new one (the name).
        public var correctDish: @Sendable (_ reviewID: UUID, _ dishID: UUID?, _ dishName: String?) async throws -> Void

        public init(
            fetch: @escaping @Sendable (UUID) async throws -> EntryCard,
            correctPlace: @escaping @Sendable (UUID, UUID) async throws -> EntryCard,
            resort: @escaping @Sendable (UUID) async throws -> Void,
            correctDish: @escaping @Sendable (UUID, UUID?, String?) async throws -> Void = { _, _, _ in }
        ) {
            self.fetch = fetch
            self.correctPlace = correctPlace
            self.resort = resort
            self.correctDish = correctDish
        }

        /// The entry service's own calls. The re-print is forced (the first sort already ran) and
        /// carries the chips the entry was written with.
        public static func live(
            _ entries: any EntryService, tagTokens: [TagToken], sixTokens: [TagToken] = []
        ) -> Actions {
            Actions(
                fetch: { try await entries.entry(id: $0) },
                correctPlace: { try await entries.correctPlace(entryID: $0, restaurantID: $1) },
                // …and its secret 6s: a forced sort rebuilds every line, and a 6 not carried here
                // would print as whatever the prose says.
                resort: {
                    _ = try await entries.sort(entryID: $0, force: true, tagTokens: tagTokens, sixTokens: sixTokens)
                },
                correctDish: { try await entries.correctDish(reviewID: $0, dishID: $1, dishName: $2) }
            )
        }
    }

    public private(set) var card: EntryCard
    public private(set) var phase: Phase
    /// True while an action is in flight (a place being attached, a re-print): the pills hold still.
    public private(set) var isBusy = false
    /// The share sheet is up. Share does nothing until it is down again.
    public private(set) var isSharing = false
    /// A place is being attached to a placeless receipt: it stays on screen while that lands.
    public private(set) var isAttachingPlace = false
    private var hasFinished = false

    private let actions: Actions
    private let pollInterval: Duration
    private let maxPolls: Int

    public init(
        card: EntryCard,
        pollInterval: Duration = .milliseconds(700),
        maxPolls: Int = 30,
        actions: Actions
    ) {
        self.card = card
        self.phase = Self.phase(for: card)
        self.actions = actions
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    /// Asks again until the row has settled, or the patience runs out. A fetch that fails (offline,
    /// the outbox still holding the entry) is one more wait, not the end.
    public func watch() async {
        guard phase == .sorting else { return }
        for _ in 0..<maxPolls {
            if pollInterval > .zero { try? await Task.sleep(for: pollInterval) }
            // The sort's own answer may have landed meanwhile (``adopt(_:)``, ``sortFailed()``):
            // nothing this watch reads afterwards may change a receipt that has moved on.
            guard Task.isCancelled == false, phase == .sorting else { return }
            guard let next = try? await actions.fetch(card.id) else { continue }
            // The sort's own answer got here first (``adopt(_:)``): a fetch that left before it
            // landed must not put the receipt back to waiting.
            guard phase == .sorting else { return }
            card = next
            phase = Self.phase(for: next)
            if phase != .sorting { return }
        }
        guard phase == .sorting else { return }
        phase = .stalled
    }

    /// **Round 5: the receipt is on screen only once its shape is final** — printed whole, never
    /// grown from a skeleton. The one exception is the placeless receipt, whose place slot is the
    /// Place key (unreachable while Post requires a place, kept whole for the server's sake).
    public var showsReceipt: Bool {
        switch phase {
        case .printed, .needsPlace: true
        case .sorting: isAttachingPlace
        case .stalled: false
        }
    }

    /// The sort's own answer, heard the moment it lands (the composer's latch) rather than at the
    /// next poll. Only while the receipt is still waiting, and only for this entry.
    public func adopt(_ next: EntryCard) {
        guard phase == .sorting, isBusy == false, next.id == card.id else { return }
        card = next
        phase = Self.phase(for: next)
    }

    /// The sort itself failed (the composer's latch heard it): the re-print is offered at once,
    /// rather than after the watch's whole patience.
    public func sortFailed() {
        guard phase == .sorting, isBusy == false else { return }
        phase = .stalled
    }

    // MARK: - Recovering

    /// The Place key in the receipt's place slot: attach it, and the parked plan prints.
    public func attachPlace(_ restaurantID: UUID) async {
        guard phase == .needsPlace || phase == .stalled, isBusy == false else { return }
        isBusy = true
        isAttachingPlace = true
        defer {
            isBusy = false
            isAttachingPlace = false
        }
        phase = .sorting
        if let updated = try? await actions.correctPlace(card.id, restaurantID) {
            card = updated
            phase = Self.phase(for: updated)
        }
        if phase == .sorting { await watch() } else if phase == .needsPlace { phase = .stalled }
    }

    /// "Print it again": a forced re-sort, then the same watch.
    public func reprint() async {
        guard phase == .stalled, isBusy == false else { return }
        isBusy = true
        defer { isBusy = false }
        phase = .sorting
        do {
            try await actions.resort(card.id)
        } catch {
            phase = .stalled
            return
        }
        if let next = try? await actions.fetch(card.id) {
            card = next
            phase = Self.phase(for: next)
        }
        if phase == .sorting { await watch() }
    }

    /// A dish name tapped on the printed receipt and fixed in "Which dish?": the name only (the score
    /// and the words stay), then the row is read again so the line reprints in place. `false` when
    /// it could not be fixed; the receipt keeps the name it had.
    public func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async -> Bool {
        guard phase == .printed, isBusy == false else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await actions.correctDish(reviewID, dishID, dishName)
        } catch {
            return false
        }
        // A re-read that fails or comes back unprintable leaves the receipt as it was, never blank.
        if let next = try? await actions.fetch(card.id), Self.phase(for: next) == .printed {
            card = next
        }
        return true
    }

    // MARK: - The two pills, each counted once

    /// Share was tapped. The event, the first time for each sheet — `nil` while one is already up,
    /// or when there is nothing printed to send.
    public func share() -> AnalyticsEvent? {
        guard phase == .printed, isSharing == false, hasFinished == false else { return nil }
        isSharing = true
        return EntryEvents.summaryShared(entryID: card.id)
    }

    /// The share sheet went away, or the render failed: Share can be tapped again.
    public func shareEnded() {
        isSharing = false
    }

    /// Done was tapped. The event exactly once — a second tap on a screen already leaving is not a
    /// second Done.
    public func done() -> AnalyticsEvent? {
        guard hasFinished == false else { return nil }
        hasFinished = true
        return EntryEvents.summaryDone(entryID: card.id, wasPrinted: phase == .printed)
    }

    static func phase(for card: EntryCard) -> Phase {
        switch card.sortStatus {
        case .pending: return .sorting
        case .failed: return .stalled
        case .sorted:
            guard card.place != nil else { return .needsPlace }
            return card.items.isEmpty ? .stalled : .printed
        }
    }
}
