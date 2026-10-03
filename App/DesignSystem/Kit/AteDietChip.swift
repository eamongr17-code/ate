import AteKit
import SwiftUI

/// **A diet tag** — GF, DF, V, VG, NF: the code in capitals, Bricolage 600 at 10.5, muted, on an 18pt
/// pill of the ground showing through (`.diet`). No stroke. The existing ``DietTagChip``, with the one
/// decision a caller makes named: whether it sits on paper (a slip, a sheet) or on the ground itself,
/// where a linen chip on linen would be no chip at all and it recesses to the field tone instead.
struct AteDietChip: View {
    let tag: DietTag
    var onGround = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        DietTagChip(tag: tag, fill: onGround ? palette.field : AteColor.tagFill)
    }
}

/// A dish's tags in a row after its name — 4 apart (`.dname .diet + .diet`).
struct AteDietChips: View {
    let tags: [DietTag]
    var onGround = false

    var body: some View {
        if tags.isEmpty == false {
            HStack(spacing: TokenPillMetrics.dietGapBetween) {
                ForEach(tags, id: \.self) { AteDietChip(tag: $0, onGround: onGround) }
            }
        }
    }
}
