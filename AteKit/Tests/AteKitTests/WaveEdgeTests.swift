import Foundation
import Testing
@testable import AteKit

@Suite("Edge B — the scallop fitted to the width")
struct WaveEdgeTests {
    @Test("the board's own widths fit a whole number of scallops", arguments: [
        (366.0, 30, 12.2),
        (350.0, 29, 12.068_965),
        (286.0, 24, 11.916_666)
    ])
    func fitted(width: Double, count: Int, period: Double) {
        #expect(WaveEdge.periodCount(forWidth: width) == count)
        #expect(abs(WaveEdge.period(forWidth: width) - period) < 0.001)
    }

    @Test("both ends land on a valley, and the middle of a period is the crest")
    func symmetrical() {
        let width = 366.0
        let period = WaveEdge.period(forWidth: width)
        #expect(abs(WaveEdge.depth(atX: 0, width: width) - WaveEdge.valley) < 0.0001)
        #expect(abs(WaveEdge.depth(atX: width, width: width) - WaveEdge.valley) < 0.0001)
        #expect(abs(WaveEdge.depth(atX: period / 2, width: width) - WaveEdge.crest) < 0.0001)
        // Mirror-symmetric about the centre of the card.
        #expect(abs(WaveEdge.depth(atX: 37, width: width) - WaveEdge.depth(atX: width - 37, width: width)) < 0.0001)
    }

    @Test("a sliver still gets one scallop, and nothing divides by zero")
    func degenerate() {
        #expect(WaveEdge.periodCount(forWidth: 3) == 1)
        #expect(WaveEdge.periodCount(forWidth: 0) == 1)
        #expect(WaveEdge.period(forWidth: 0) == WaveEdge.targetPeriod)
    }
}
