import Foundation

/// **What an early sort is asked about** — `sort-entry` with `"preview": true` (backend contract,
/// round 3): the words, the tag chips and the place, and nothing else. The server returns a plan,
/// persists nothing, and caches it; the real sort after Done reuses it when these inputs match.
public struct EarlySortInput: Hashable, Sendable {
    public let body: String
    public let tagTokens: [TagToken]
    /// The secret 6s (`six_tokens`) — part of the input, so a plan cached without them is never
    /// reused for words that hold one.
    public let sixTokens: [TagToken]
    public let restaurantID: UUID

    public init(body: String, tagTokens: [TagToken], sixTokens: [TagToken] = [], restaurantID: UUID) {
        self.body = body
        self.tagTokens = tagTokens
        self.sixTokens = sixTokens
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
        self.init(
            body: composition.plain,
            tagTokens: composition.tagTokens,
            sixTokens: composition.sixTokens,
            restaurantID: restaurantID
        )
    }

    public static let minimumCharacters = 12
}

/// **The early sort's trigger** — debounced, one at a time, and rationed.
///
/// Every edit calls ``edited(_:)`` with what the words now are (or `nil` when they are not worth a
/// preview). The rules, each unit-tested:
///
/// - while typing, a preview goes only after the person has **paused** for ``pause`` (1.5s);
/// - a **settled moment** — a place attached or changed, the score slide closed, a diet chip added,
///   the keyboard down, Done — sends it **at once** (``now(_:)``), since nothing more is being typed;
/// - an edit **cancels** the pending one *and* any preview in flight whose inputs it made stale — a
///   preview already out for exactly these inputs is left to land;
/// - **never more than one at a time**: a new preview waits for a cancelled one to unwind first;
/// - an input already previewed (or in flight) is not asked about again;
/// - at most ``limit`` (12) are sent in a session, then it stops.
///
/// Done does not wait on any of this: it asks ``now(_:)`` for the words being saved (a stale key gets
/// one last preview, which the server's sort waits on for up to 3s) and then sorts as it always has.
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
    /// The input whose preview is out right now.
    public private(set) var inFlight: EarlySortInput?

    private let send: Send
    private let sleep: Sleep
    private let onSent: (Int) -> Void
    /// Waiting out the typing pause.
    private var pending: Task<Void, Never>?
    /// The preview on the wire (or about to be).
    private var flight: Task<Void, Never>?
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

    /// True while a preview's request is out.
    public var isInFlight: Bool { inFlight != nil }

    /// Whether the server has (or is about to have) a plan for exactly these inputs — the preview
    /// landed, or is out now. What Done's `cache_hit` reports.
    public func covers(_ input: EarlySortInput?) -> Bool {
        guard let input else { return false }
        return input == lastCompleted || input == inFlight
    }

    /// The words (or the place) changed while typing: preview after the pause.
    public func edited(_ input: EarlySortInput?) {
        pending?.cancel()
        pending = nil
        dropStaleFlight(for: input)
        guard let input, accepts(input) else { return }
        pending = Task { [weak self, sleep, pause] in
            do {
                try await sleep(pause)
            } catch {
                return
            }
            guard Task.isCancelled == false, let self else { return }
            self.launch(input)
        }
    }

    /// A settled moment: preview these inputs **now**, without waiting for a pause. Works after
    /// ``stop()`` too — Done's last word — but never past the ration.
    public func now(_ input: EarlySortInput?) {
        pending?.cancel()
        pending = nil
        dropStaleFlight(for: input)
        guard let input, sentCount < limit, covers(input) == false else { return }
        launch(input)
    }

    /// Done, or the composer closed: nothing further goes on its own. A preview already in flight
    /// for the words being saved is left to finish — its plan is what the real sort will reuse.
    public func stop(cancellingInFlight: Bool = false) {
        isStopped = true
        pending?.cancel()
        pending = nil
        if cancellingInFlight { flight?.cancel() }
    }

    /// Waits for whatever is scheduled or in flight — tests, and nothing else.
    public func settle() async {
        await pending?.value
        await flight?.value
    }

    private func accepts(_ input: EarlySortInput) -> Bool {
        isStopped == false && sentCount < limit && covers(input) == false
    }

    /// A preview out for inputs these words no longer are: its plan is useless, so it goes.
    private func dropStaleFlight(for input: EarlySortInput?) {
        guard let inFlight, inFlight != input else { return }
        flight?.cancel()
        // Cancelled is not out: the same words coming back are asked about again.
        self.inFlight = nil
    }

    private func launch(_ input: EarlySortInput) {
        guard sentCount < limit, covers(input) == false else { return }
        let previous = flight
        previous?.cancel()
        inFlight = input
        flight = Task { [weak self] in
            // One at a time: whatever was cancelled finishes unwinding before this one goes.
            await previous?.value
            guard let self else { return }
            await self.fire(input)
        }
    }

    private func fire(_ input: EarlySortInput) async {
        defer { if inFlight == input { inFlight = nil } }
        guard Task.isCancelled == false, sentCount < limit else { return }
        sentCount += 1
        onSent(sentCount)
        do {
            try await send(input)
            guard Task.isCancelled == false else { return }
            lastCompleted = input
        } catch {
            // A preview is only ever a head start. Failing one costs nothing: Done sorts as always.
        }
    }
}
