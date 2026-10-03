import CoreGraphics
import Testing
@testable import AteKit

@Suite("Every sheet's header is one layout")
struct SheetHeaderGeometryTests {
    @Test("the close disc is the same frame on every kind of sheet, at every width")
    func closeNeverMoves() {
        for width in [375.0, 390, 402, 440] {
            let frames = SheetHeaderGeometry.Variant.allCases.map {
                SheetHeaderGeometry.layout(for: $0, width: width).close
            }
            #expect(Set(frames.map { "\($0)" }).count == 1)
            #expect(frames[0] == CGRect(x: 16, y: 14, width: 44, height: 44))
        }
    }

    @Test("the title starts at 72 on every kind of sheet, on the gutter")
    func titleNeverMoves() {
        for variant in SheetHeaderGeometry.Variant.allCases {
            let layout = SheetHeaderGeometry.layout(for: variant, width: 402)
            #expect(layout.titleTop == 72)
            #expect(layout.titleLeading == 20)
        }
    }

    @Test("the primary disc is present only with a primary, mirroring the close disc")
    func primaryMirrors() {
        let width: CGFloat = 402
        let layout = SheetHeaderGeometry.layout(for: .primary, width: width)
        let primary = try? #require(layout.primary)
        #expect(primary?.minY == layout.close.minY)
        #expect(primary.map { width - $0.maxX } == layout.close.minX)
        #expect(SheetHeaderGeometry.layout(for: .pick, width: width).primary == nil)
        #expect(SheetHeaderGeometry.layout(for: .choice, width: width).primary == nil)
    }
}
