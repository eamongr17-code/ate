import Foundation

/// **What an early sort is asked about** — `sort-entry` with `"preview": true` (backend contract,
/// round 3): the words, the tag chips and the place, and nothing else. The server returns a plan,
/// persists nothing, and caches it; the real sort after Done reuses it when these inputs match.
public struct EarlySortInput: Hashable, Sendable {
    public let body: String
    public let tagTokens: [TagToken]
    public let restaurantID: UUID

    public init(body: String, tagTokens: [TagToken], restaurantID: UUID) {
        self.body = body
        self.tagTokens = tagTokens
        self.restaurantID = restaurantID
    }

    /// Worth previewing, or `nil`: a place is set (nothing prints without one), and the words hold
    /// at least one dish-like token — a score or a tag chip, each of which only ever follows a dish —
    /// or ``minimumCharacters`` of text.
    public init?(composition: EntryComposition, restaurantID: UUID?) {
        guard let restaurantID else { return nil }
        let hasDishToken = composition.spans.contains { $0.token.score != nil || $0.token.tag != nil }
        let length = composition.plain.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard hasDishToken || length >= Self.minimumCharacters else { return nil }
        self.init(body: composition.plain, tagTokens: composition.tagTokens, restaurantID: restaurantID)
    }

    public static let minimumCharacters = 12
}

/// **The early sort's trigger** — debounced, one at a time, and rationed.
///
/// Every edit calls ``edited(_:)`` with what the words now are (or `nil` when they are not worth a
/// preview). The rules, each unit-tested:
///
/// - a preview goes only after the person has **paused typing** for ``pause`` (1.5s);
/// - an edit **cancels** the pending one *and* any preview in flight — its inputs are stale;
/// - **never more than one at a time**: a new preview waits for a cancelled one to unwind first;
/// - an input already previewed is not asked about again;
/// - at most ``limit`` (12) are sent in a session, then it stops.
///
/// Done does not wait on any of this: it calls the normal sort as it always has, and the server
/// reuses a cached plan when the inputs match.
@MainActor
public final class EarlySortScheduler {
    public typealias Send = @Sendable (EarlySortInput) async throws -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let defaultPause: Duration = .milliseconds(1500)
    public static let defaultLimit = 12

    public let pause: Duration
    public let limit: Int
    /// How many previews have been sent this session.
    public private(set) var sentCount = 0
    /// The last input a preview finished for.
    public private(set) var lastCompleted: EarlySortInput?

    private let send: Send
    private let sleep: Sleep
    private let onSent: (Int) -> Void
    private var task: Task<Void, Never>?
    /// True while a preview's request is out.
    public private(set) var isInFlight = false
    private var isStopped = false

    public init(
        pause: Duration = EarlySortScheduler.defaultPause,
        limit: Int = EarlySortScheduler.defaultLimit,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        onSent: @escaping (Int) -> Void = { _ in },
        send: @escaping Send
    ) {
        self.pause = pause
        self.limit = limit
        self.sleep = sleep
        self.onSent = onSent
        self.send = send
    }

    /// The words (or the place) changed.
    public func edited(_ input: EarlySortInput?) {
        let previous = task
        previous?.cancel()
        task = nil
        guard let input, isStopped == false, sentCount < limit, input != lastCompleted else { return }
        task = Task { [weak self, sleep, pause] in
            do {
                try await sleep(pause)
            } catch {
                return
            }
            // One at a time: whatever was cancelled finishes unwinding before this one goes.
            await previous?.value
            guard Task.isCancelled == false, let self else { return }
            await self.fire(input)
        }
    }

    /// Done, or the composer closed: nothing further goes. A preview already in flight for the
    /// words being saved is left to finish — its plan is what the real sort will reuse.
    public func stop(cancellingInFlight: Bool = false) {
        isStopped = true
        if cancellingInFlight || isInFlight == false { task?.cancel() }
    }

    /// Waits for whatever is scheduled or in flight — tests, and nothing else.
    public func settle() async {
        await task?.value
    }

    private func fire(_ input: EarlySortInput) async {
        guard isStopped == false, sentCount < limit else { return }
        sentCount += 1
        onSent(sentCount)
        isInFlight = true
        defer { isInFlight = false }
        do {
            try await send(input)
            guard Task.isCancelled == false else { return }
            lastCompleted = input
        } catch {
            // A preview is only ever a head start. Failing one costs nothing: Done sorts as always.
        }
    }
}
