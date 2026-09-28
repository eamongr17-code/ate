import Foundation
import Observation

/// **A count that follows a draft** — a chip sheet's "Show N entries" (round 7, `my_entries_count`).
///
/// Each change to the draft asks again after a short pause (a slider's thumb passes many stops on the
/// way), the older ask is dropped, and an answer is kept per draft so going back to one is instant.
/// Until the new answer lands the last one stays up, so the button never blinks empty mid-drag.
@MainActor
@Observable
public final class LiveCount<Draft: Hashable & Sendable> {
    /// The count for the draft asked about last — or, while that is being read, the one before it.
    public private(set) var count: Int?
    /// The draft the count is for.
    public private(set) var draft: Draft?

    @ObservationIgnored private let read: @Sendable (Draft) async throws -> Int
    @ObservationIgnored private let pause: Duration
    @ObservationIgnored private var answers: [Draft: Int] = [:]
    @ObservationIgnored private var asking: Task<Void, Never>?

    public init(pause: Duration = .milliseconds(220), read: @escaping @Sendable (Draft) async throws -> Int) {
        self.pause = pause
        self.read = read
    }

    /// Ask for `draft`'s count. Answered at once when it has been asked before.
    public func request(_ draft: Draft) {
        self.draft = draft
        asking?.cancel()
        if let known = answers[draft] {
            count = known
            return
        }
        let read = read
        let pause = pause
        asking = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard Task.isCancelled == false else { return }
            guard let answer = try? await read(draft) else { return }
            guard Task.isCancelled == false, let self else { return }
            self.answers[draft] = answer
            if self.draft == draft { self.count = answer }
        }
    }

    /// Waits for the ask in flight — tests, and a caller that must have the number.
    public func settle() async {
        await asking?.value
    }
}
