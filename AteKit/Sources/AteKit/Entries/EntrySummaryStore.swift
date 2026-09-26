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

        public init(
            fetch: @escaping @Sendable (UUID) async throws -> EntryCard,
            correctPlace: @escaping @Sendable (UUID, UUID) async throws -> EntryCard,
            resort: @escaping @Sendable (UUID) async throws -> Void
        ) {
            self.fetch = fetch
            self.correctPlace = correctPlace
            self.resort = resort
        }

        /// The entry service's own calls. The re-print is forced (the first sort already ran) and
        /// carries the chips the entry was written with.
        public static func live(_ entries: any EntryService, tagTokens: [TagToken]) -> Actions {
            Actions(
                fetch: { try await entries.entry(id: $0) },
                correctPlace: { try await entries.correctPlace(entryID: $0, restaurantID: $1) },
                resort: { _ = try await entries.sort(entryID: $0, force: true, tagTokens: tagTokens) }
            )
        }
    }

    public private(set) var card: EntryCard
    public private(set) var phase: Phase
    /// True while an action is in flight (a place being attached, a re-print): the pills hold still.
    public private(set) var isBusy = false
    /// The share sheet is up. Share does nothing until it is down again.
    public private(set) var isSharing = false
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
            guard Task.isCancelled == false else { return }
            guard let next = try? await actions.fetch(card.id) else { continue }
            card = next
            phase = Self.phase(for: next)
            if phase != .sorting { return }
        }
        phase = .stalled
    }

    // MARK: - Recovering

    /// The Place key in the receipt's place slot: attach it, and the parked plan prints.
    public func attachPlace(_ restaurantID: UUID) async {
        guard phase == .needsPlace || phase == .stalled, isBusy == false else { return }
        isBusy = true
        defer { isBusy = false }
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
