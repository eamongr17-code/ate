import Foundation

/// **Near me, for the feed's reads** (round 5, after QA on #84).
///
/// Every first page — the first load, a pull to refresh, a reload after a sign-in or a pick — asks
/// ``cityForFirstPage(wait:)`` which city to read. On near me:
/// - not worked out yet: it waits for the phone and `resolve_city`, **at most `wait`**; past that it
///   reads the last near me this phone had (or the busiest city) and lets the real answer reload
///   the feed when it lands — never an Everywhere flashed under a Near me chip;
/// - worked out: it reads that city at once and asks again in the background, so a phone that has
///   moved (or a read that failed before) catches up; a different answer reloads the feed.
///
/// A failed or cancelled read is never an answer, so it is simply asked again next time.
extension FeedAreaModel {
    public func cityForFirstPage(wait: Duration = .seconds(2)) async -> String? {
        await openIfNeeded()
        // A read is under way: an answer landing now is picked up by it, not reloaded for.
        servedCity = nil
        if location == .nearMe {
            let task = startResolving()
            if hasResolvedNearMe == false {
                _ = await Self.finishes(task, within: wait)
                // Still no answer — the wait ran out, or the read failed inside it: a stand-in,
                // never Everywhere under a Near me chip (QA on #84).
                if hasResolvedNearMe == false { await fallBack() }
            }
        }
        let served = city
        servedCity = .some(served)
        return served
    }

    /// The city the pages after the first are read with — the one the first page was.
    public var cityForNextPage: String? {
        switch servedCity {
        case .some(let served): served
        case .none: city
        }
    }

    /// One read of near me at a time; a second ask joins the one in the air.
    @discardableResult
    func startResolving() -> Task<Void, Never> {
        if let resolving { return resolving }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let point = await self.locate?()
            await self.resolveNearMe(latitude: point?.latitude, longitude: point?.longitude)
            self.resolving = nil
            // Served, and the answer moved the city: the feed on screen is the wrong one.
            if case .some(let served) = self.servedCity, served != self.city {
                self.onNearMeChanged?()
            }
        }
        resolving = task
        return task
    }

    /// Whether `task` finishes within `limit` — without cancelling it when it does not.
    static func finishes(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let race = Race(continuation)
            Task { @MainActor in
                await task.value
                race.finish(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                race.finish(false)
            }
        }
    }
}

/// The first of two to finish, once.
@MainActor
private final class Race {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
