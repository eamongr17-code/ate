import Foundation

/// **What a forced re-sort carries** — the entry's tag chips and secret 6s — so "Print it again"
/// never prints a 6 as prose (round 4).
///
/// Two stores, in order of trust:
/// 1. **The outbox**, which kept the composition's own tokens with the entry until its sort lands —
///    the only place a 6 lives after a first sort that failed (the sorter never infers one).
/// 2. **The entry's lines**, rebuilt into the words (``EntryBodyTokens``) — a sorted entry's 6s and
///    chips are on its lines, and the pills rebuilt from them are what the words say now.
public struct ResortTokens: Equatable, Sendable {
    public let tags: [TagToken]
    public let sixes: [TagToken]

    public init(tags: [TagToken], sixes: [TagToken]) {
        self.tags = tags
        self.sixes = sixes
    }

    public static func resolve(queued: QueuedEntry?, card: EntryCard?) -> ResortTokens {
        if let queued, queued.tagTokens != nil || queued.sixTokens != nil {
            return ResortTokens(tags: queued.tagTokens ?? [], sixes: queued.sixTokens ?? [])
        }
        guard let card else { return ResortTokens(tags: [], sixes: []) }
        let words = EntryBodyTokens.composition(for: card)
        return ResortTokens(tags: words.tagTokens, sixes: words.sixTokens)
    }
}

/// Waiting on something, **but not forever** — Done waits on picks still being written, and a slow
/// iCloud original must not hold the entry hostage (round 4: about 8s, then it saves without it).
public enum BoundedWait {
    public static let pendingPhotos: Duration = .seconds(8)

    /// Polls `isDone` until it holds or `timeout` passes. Returns whether it held.
    @MainActor
    public static func until(
        timeout: Duration,
        poll: Duration = .milliseconds(50),
        _ isDone: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isDone() == false {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }
}
