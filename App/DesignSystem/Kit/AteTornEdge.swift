import AteKit
import SwiftUI

/// **Edge B** — the 4pt wave under a piece of paper, its period fitted to the width so both ends
/// match: `P = W / round(W/12)`, `y = 2.1 − 1.5·cos(2πx/P)` (valley 0.6, crest 3.6). On dish entry
/// slips, the place menu and every receipt; nowhere else. The paper is flat: one tone to the tip.
///
/// The strip alone, for paper that draws its own body (the place menu's sheet of rows). Paper that
/// is one shape — a slip, a receipt — takes ``SwiftUICore/View/ateTornPaper(_:topRadius:)``, which
/// is the same wave joined to the paper so there is no seam.
struct AteTornEdge: View {
    var tone: AtePaperTone = .slip

    var body: some View {
        AteTornEdgeShape()
            .fill(tone.fill)
            .ateContactLine(tone)
            .frame(height: AteMetrics.tornEdgeHeight)
            .accessibilityHidden(true)
    }
}

/// The wave, its paper side flush with the top of the rect.
struct AteTornEdgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        ReceiptPaper.wave(width: rect.width, originX: rect.minX, bottom: rect.minY)
    }
}
