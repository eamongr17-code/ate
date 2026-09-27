import Foundation

/// **A value that arrives once, waited on with a deadline.** The composer's Post fills it with the
/// entry as the sort left it; the "Posting…" hold waits on it, but never past its deadline — and a
/// wait that gives up cancels nothing: the sort goes on, and whoever asks later still gets it.
public actor Latch<Value: Sendable> {
    private var value: Value?
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    public init() {}

    /// The value, the first time only. Later calls are ignored — it arrives once.
    public func fulfil(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values { continuation.resume(returning: value) }
    }

    /// The value if it is here, or as soon as it lands — or `nil` once `deadline` passes first.
    public func value(before deadline: ContinuousClock.Instant) async -> Value? {
        if let value { return value }
        guard deadline > .now else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

/// **How long "Posting…" holds** (round 5, Eamon): after Post, the pill says "Posting…" while the
/// sorter works, so the receipt can arrive already whole instead of printing and then changing shape.
///
/// - At least ``minimum``, so the word reads as a beat rather than a flicker — a cached early sort
///   can answer faster than that.
/// - At most ``maximum``. A sort that is still out by then does not keep the words hostage: the
///   Summary comes up anyway, and its receipt enters only when it is final (``EntrySummaryStore``).
public struct PostHold: Sendable, Equatable {
    public var minimum: Duration
    public var maximum: Duration

    public init(minimum: Duration = .milliseconds(700), maximum: Duration = .milliseconds(3500)) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public static let standard = PostHold()

    /// What the hold ended on.
    public enum Outcome: String, Sendable, Equatable {
        /// The sort answered inside the hold — the receipt comes up whole.
        case sorted
        /// The sort answered, but with nothing that prints (failed, or no lines).
        case unprinted
        /// The hold ran out first: the Summary comes up and waits for the receipt.
        case late
    }

    /// Which way a hold ended: what landed on the latch (`nil` — nothing did), and whether it prints.
    @MainActor
    public static func outcome(_ landed: EntryCard??) -> Outcome {
        switch landed {
        case .none: .late
        case .some(.none): .unprinted
        case .some(.some(let card)): EntrySummaryStore.phase(for: card) == .printed ? .sorted : .unprinted
        }
    }

    /// Whole milliseconds since `start`, for the hold's telemetry.
    public static func milliseconds(
        since start: ContinuousClock.Instant, now: ContinuousClock.Instant = .now
    ) -> Int {
        let elapsed = now - start
        return max(0, Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
    }

    /// Waits on `latch` from `start` — the Post tap — for at least ``minimum`` and at most
    /// ``maximum``. Returns what landed (`nil` when the hold ran out first).
    public func wait<Value: Sendable>(
        on latch: Latch<Value>, from start: ContinuousClock.Instant
    ) async -> Value? {
        let landed = await latch.value(before: start + maximum)
        try? await Task.sleep(until: start + minimum, clock: .continuous)
        return landed
    }
}
