import Foundation
import Synchronization

/// **A sheet rises once what it shows is in hand** (round 5: sheets opened blank, then jumped full).
///
/// The presenter runs the sheet's first read, and presents when it answers — or when ``limit`` has
/// passed, whichever is first. Past the limit the sheet goes up anyway, at its full height with its
/// rows drawn still, and fills in without moving. The read is never cut short by the limit: it keeps
/// going and lands in the sheet that is already up.
public enum SheetReadiness {
    /// How long a tap waits for a sheet's read before the sheet goes up without it.
    public static let limit: Duration = .milliseconds(700)
    /// How long a sheet that was asked to go up has to actually appear before the ask is let go
    /// (something else was already up over the page, and the system refused it).
    public static let riseGrace: Duration = .milliseconds(1500)

    /// Runs `work` and returns when it has finished (`true`) or when `limit` has passed (`false`).
    @MainActor
    @discardableResult
    public static func wait(
        atMost limit: Duration = SheetReadiness.limit,
        for work: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            Task { @MainActor in
                await work()
                gate.open(finished: true)
            }
            Task {
                try? await Task.sleep(for: limit)
                gate.open(finished: false)
            }
        }
    }

    /// Resumes its continuation once, for whichever of the two gets there first.
    private final class Gate: Sendable {
        private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = Mutex(continuation)
        }

        func open(finished: Bool) {
            continuation.withLock { waiting in
                waiting?.resume(returning: finished)
                waiting = nil
            }
        }
    }
}
