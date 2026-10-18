import Foundation

/// **What a forced re-sort carries** — the entry's tag chips and secret 6s — so "Try again"
/// never prints a 6 as prose (round 4).
///
/// Two stores, in order of trust:
/// 1. **The outbox**, which kept the composition's own tokens with the entry until its sort lands —
///    the only place a 6 lives after a first sort that failed (the sorter never infers one).
/// 2. **The entry's lines**, rebuilt into the words (``EntryBodyTokens``) — a sorted entry's 6s and
///    chips are on its lines, and the pills rebuilt from them are what the words say now.
public struct ResortTokens: Equatable, Sendable {
    public let tags: [TagToken]
    /// Every score pill (`score_tokens`), its 6s included; `nil` when an old outbox kept none.
    public let scores: [TagToken]?

    public init(tags: [TagToken], scores: [TagToken]?) {
        self.tags = tags
        self.scores = scores
    }

    public static func resolve(queued: QueuedEntry?, card: EntryCard?) -> ResortTokens {
        if let queued, queued.tagTokens != nil || queued.scoreTokens != nil {
            return ResortTokens(tags: queued.tagTokens ?? [], scores: queued.scoreTokens)
        }
        // Nothing known: no `score_tokens` at all. An empty list would tell the server "no ratings".
        guard let card else { return ResortTokens(tags: [], scores: nil) }
        let words = EntryBodyTokens.composition(for: card)
        return ResortTokens(tags: words.tagTokens, scores: scoreTokens(of: words, rebuiltFrom: card.items))
    }

    /// The pills of words rebuilt from an entry's lines — or `nil` when a scored line got none back
    /// (an older entry scored from prose, "a solid four"). Sending pills that miss a rated line would
    /// have the sorter drop that dish; without them the server reads the prose as it did.
    public static func scoreTokens(of words: EntryComposition, rebuiltFrom items: [EntryCard.Item]) -> [TagToken]? {
        let pills = words.spans.filter { $0.token.score != nil }.count
        return pills >= items.filter { $0.score != nil }.count ? words.scoreTokens : nil
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
