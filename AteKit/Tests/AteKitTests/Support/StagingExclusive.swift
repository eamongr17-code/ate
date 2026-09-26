import Foundation

/// Cursor walks and visibility writers are mutually exclusive within one test process.
///
/// Swift Testing runs suites in parallel. `blockingHidesThem` blocks a seeded author for four round
/// trips and `blocked_with()` hides that author's rows from every read while it holds — so a walk
/// running at the same moment loses rows that are back by the time it finishes, and no snapshot
/// taken before or after can tell that from a pager skipping them. Every walk and every test that
/// changes what the viewer can see runs inside this lock. So do the save round trips and every test
/// that asks the save state twice (a save landing between `dish_summary.saved` and `is_dish_saved`
/// is two right answers that disagree), and the entry writers (`StatsProbe`, the tag probe). Fair
/// (FIFO) and never blocks a thread.
actor StagingExclusive {
    static let shared = StagingExclusive()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if held == false {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
