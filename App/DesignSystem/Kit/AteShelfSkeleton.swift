import SwiftUI

/// **A shelf while it is read** — three shelf-card skeletons on the shelf's own run and margins, held
/// still (no scroll), so nothing moves when the real cards fill in.
struct AteShelfSkeleton: View {
    var cards = AteShelfSkeletonMetrics.cards

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: AteShelfCardMetrics.spacing) {
                ForEach(0..<cards, id: \.self) { _ in
                    AteSkeleton(kind: .shelfCard)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .contentMargins(.horizontal, AteMetrics.gutter, for: .scrollContent)
        .accessibilityHidden(true)
    }
}

enum AteShelfSkeletonMetrics {
    static let cards = 3
}
