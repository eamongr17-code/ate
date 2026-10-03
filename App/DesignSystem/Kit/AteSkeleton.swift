import SwiftUI

/// **Loading** — skeletons of the real components, breathing to 45% and back (never a spinner on a
/// first load). Each kind is drawn at its component's own size and rhythm, so nothing moves when the
/// real thing fills in.
struct AteSkeleton: View {
    enum Kind: Equatable {
        case dishRow, rankedRow, shelfCard, hero, entrySlip
    }

    let kind: Kind
    var breathes = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        Group {
            switch kind {
            case .dishRow: dishRow
            case .rankedRow: rankedRow
            case .shelfCard: shelfCard
            case .hero: block(AteThumbMetrics(.hero))
            case .entrySlip: entrySlip
            }
        }
        .ateBreathing(breathes)
        .accessibilityHidden(true)
    }

    private var dishRow: some View {
        HStack(spacing: AteDishRowMetrics.gap) {
            block(AteThumbMetrics(.row))
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteSkeletonBar(width: 150, height: 14, palette: palette)
                AteSkeletonBar(width: 84, height: 11, palette: palette)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AteSkeletonBar(width: 46, height: 22, palette: palette)
        }
        .frame(minHeight: AteDishRowMetrics.height)
    }

    private var rankedRow: some View {
        HStack(spacing: AteRankedRowMetrics.gap) {
            AteSkeletonBar(width: 18, height: 24, palette: palette)
                .frame(width: AteRankedRowMetrics.rankWidth)
            block(AteThumbMetrics(.row))
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteSkeletonBar(width: 140, height: 14, palette: palette)
                AteSkeletonBar(width: 76, height: 11, palette: palette)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AteSkeletonBar(width: 46, height: 22, palette: palette)
        }
        .padding(.vertical, AteRankedRowMetrics.padding)
    }

    private var shelfCard: some View {
        VStack(alignment: .leading, spacing: AteShelfCardMetrics.gap) {
            block(AteThumbMetrics(.card))
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                AteSkeletonBar(width: 132, height: 14, palette: palette)
                AteSkeletonBar(width: 80, height: 11, palette: palette)
            }
        }
        .frame(width: AteShelfCardMetrics.width, alignment: .leading)
    }

    /// Two dish rows, two lines of words, three photo slots and the foot line, on the slip's paper.
    private var entrySlip: some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipBandGap) {
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    VStack(spacing: 0) {
                        if row > 0 { AteHairline() }
                        HStack {
                            AteSkeletonBar(width: row == 0 ? 180 : 132, height: 20)
                            Spacer(minLength: 0)
                            AteSkeletonBar(width: 58, height: 22)
                        }
                        .frame(minHeight: AteMetrics.hit)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                AteSkeletonBar(height: 14)
                AteSkeletonBar(width: 190, height: 14)
            }
            HStack(spacing: AteMetrics.snug) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(
                        cornerRadius: AteMetrics.photoRadius(side: AteMetrics.clusterPhoto),
                        style: .continuous
                    )
                    .fill(AtePalette.slip.hairline)
                    .frame(width: AteMetrics.clusterPhoto, height: AteMetrics.clusterPhoto)
                }
            }
            HStack {
                AteSkeletonBar(width: 150, height: 14)
                Spacer(minLength: 0)
                AteSkeletonBar(width: 70, height: 12)
            }
            .frame(minHeight: AteMetrics.slipFootHeight)
        }
        .padding(.top, AteMetrics.slipPaddingTopBare)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.slipPaddingBottom + AteMetrics.tornEdgeHeight)
        .ateSlip()
        .ateTornPaper()
    }

    /// A thumbnail's slot, in the surface's hairline tone.
    private func block(_ metrics: AteThumbMetrics) -> some View {
        RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            .fill(palette.hairline)
            .frame(width: metrics.width, height: metrics.height)
            .frame(maxWidth: metrics.width == nil ? .infinity : nil)
    }
}
