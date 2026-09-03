import Foundation
import Testing

@testable import AteKit

@Suite("Receipt mosaic — every dish count resolves to one composition")
struct ReceiptMosaicTests {

    @Test("each count picks its composition")
    func layouts() {
        #expect(ReceiptMosaic.layout(forItemCount: 1) == .single)
        #expect(ReceiptMosaic.layout(forItemCount: 2) == .sideBySide)
        #expect(ReceiptMosaic.layout(forItemCount: 3) == .oneLargeTwoStacked)
        #expect(ReceiptMosaic.layout(forItemCount: 4) == .grid(overflow: 0))
        #expect(ReceiptMosaic.layout(forItemCount: 7) == .grid(overflow: 3))
    }

    @Test("an empty receipt still has a band rather than a hole")
    func emptyIsSingle() {
        #expect(ReceiptMosaic.layout(forItemCount: 0) == .single)
        #expect(ReceiptMosaic.visibleCount(for: .single) == 1)
    }

    @Test("the band never draws more cells than the layout has")
    func visibleCounts() {
        for count in 0...12 {
            let layout = ReceiptMosaic.layout(forItemCount: count)
            let visible = ReceiptMosaic.visibleCount(for: layout)
            #expect(visible <= 4)
            #expect(visible >= 1)
            // Nothing is lost: what's drawn plus what's counted is what was posted.
            let hidden = ReceiptMosaic.overflowBadge(for: layout).map { Int($0.dropFirst())! } ?? 0
            #expect(visible + hidden == max(1, count))
        }
    }

    @Test("the overflow badge appears only when dishes are actually hidden")
    func overflowBadge() {
        #expect(ReceiptMosaic.overflowBadge(for: .grid(overflow: 0)) == nil)
        #expect(ReceiptMosaic.overflowBadge(for: .grid(overflow: 3)) == "+3")
        #expect(ReceiptMosaic.overflowBadge(for: .sideBySide) == nil)
    }
}
