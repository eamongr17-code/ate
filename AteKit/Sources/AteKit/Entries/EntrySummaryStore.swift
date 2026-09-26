import Foundation
import Observation

/// **The Summary after Done** (`SummaryLoading` → `SummaryFinal`, 2026-09-26): the entry's receipt as
/// the hero on the coral ground, printing while the sorter works.
///
/// What is known prints at once — the place, the photos, the order number, the date — and the lines
/// still being sorted are skeleton bars. This store is the watching half: it holds the row, asks for
/// it again until the sorter has answered, and says which of three states the receipt is in. The app
/// asked for the sort itself when the entry was saved, so this watches rather than drives, and it
/// gives up rather than hammering.
@MainActor
@Observable
public final class EntrySummaryStore {
    public enum Phase: Sendable, Equatable {
        /// The words are saved; the lines are not back yet. The skeleton breathes.
        case sorting
        /// The receipt has printed — Share is live.
        case printed
        /// The sorter failed, or took longer than anyone waits on this screen. The skeleton stops
        /// breathing and Share stays off; the entry page carries the retry.
        case stalled
    }

    public private(set) var card: EntryCard
    public private(set) var phase: Phase

    private let fetch: @Sendable (UUID) async throws -> EntryCard
    private let pollInterval: Duration
    private let maxPolls: Int

    public init(
        card: EntryCard,
        pollInterval: Duration = .milliseconds(700),
        maxPolls: Int = 30,
        fetch: @escaping @Sendable (UUID) async throws -> EntryCard
    ) {
        self.card = card
        self.phase = Self.phase(for: card)
        self.fetch = fetch
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    /// Asks again until the row is sorted or failed, or the patience runs out. A fetch that fails
    /// (offline, the outbox still holding the entry) is one more wait, not the end.
    public func watch() async {
        guard phase == .sorting else { return }
        for _ in 0..<maxPolls {
            if pollInterval > .zero { try? await Task.sleep(for: pollInterval) }
            guard Task.isCancelled == false else { return }
            guard let next = try? await fetch(card.id) else { continue }
            card = next
            phase = Self.phase(for: next)
            if phase != .sorting { return }
        }
        phase = .stalled
    }

    static func phase(for card: EntryCard) -> Phase {
        switch card.sortStatus {
        case .pending: .sorting
        case .sorted: .printed
        case .failed: .stalled
        }
    }
}
