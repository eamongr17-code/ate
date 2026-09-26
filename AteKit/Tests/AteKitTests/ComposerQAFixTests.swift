import Foundation
import Testing
@testable import AteKit

/// QA round 3, note (b): a library pick still loading must not resurrect a photo removed meanwhile.
@Suite("Staged photos merge at commit time")
struct StagedMergeTests {
    private struct Photo: Equatable { let id: String }

    @Test("a photo removed while picks load stays removed")
    func removedStaysRemoved() {
        // Loading began with [a, b]; b was long-pressed away; the pick c lands.
        let current = [Photo(id: "a")]
        let merged = StagedMerge.appending([Photo(id: "c")], to: current, id: \.id, limit: 5)
        #expect(merged.map(\.id) == ["a", "c"])
    }

    @Test("nothing already staged is added twice, and the cap holds")
    func dedupeAndCap() {
        let current = ["a", "b", "c", "d"].map(Photo.init)
        let merged = StagedMerge.appending(["b", "e", "f"].map(Photo.init), to: current, id: \.id, limit: 5)
        #expect(merged.map(\.id) == ["a", "b", "c", "d", "e"])
    }
}

/// QA round 3, note (a): the early sort is stopped only by Done or close — a full-screen cover
/// (the camera) over the composer is a pause in typing, not the end of the session.
@Suite("The early sort survives a cover")
@MainActor
struct EarlySortCoverTests {
    private let place = UUID()

    @Test("edits before and after a pause both preview; only stop() ends the session")
    func survivesPause() async {
        let sent = SentBox()
        let early = EarlySortScheduler(
            sleep: { _ in await Task.yield(); try Task.checkCancellation() },
            send: { sent.add($0.body) }
        )
        early.edited(EarlySortInput(body: "the ragù 4.5 was unreal", tagTokens: [], restaurantID: place))
        await early.settle()
        // The camera cover comes and goes; the person keeps writing.
        early.edited(EarlySortInput(body: "the ragù 4.5 was unreal, tiramisu", tagTokens: [], restaurantID: place))
        await early.settle()
        #expect(sent.all.count == 2)

        early.stop()
        early.edited(EarlySortInput(body: "after close", tagTokens: [], restaurantID: place))
        await early.settle()
        #expect(sent.all.count == 2, "closed: nothing further goes")
    }
}

private final class SentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    func add(_ body: String) { lock.withLock { bodies.append(body) } }
    var all: [String] { lock.withLock { bodies } }
}
