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
