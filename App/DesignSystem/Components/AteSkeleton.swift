import SwiftUI

/// **One line of something that has not arrived** — a still, rounded bar in the surface's hairline
/// colour. Loading in Ate is the real layout drawn in these, then filled in once (round 4): never a
/// spinner, never a shimmer, never a breath (that one is the printing receipt's alone).
///
/// `width: nil` fills the line, the way a run of words does.
struct AteSkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat
    /// The paper it sits on — slips and the entry page are `slip`, the ground is `automatic`.
    var palette: AtePalette = .slip

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(palette.hairline)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// **The entry page before its read has answered** — only when it was opened by id alone, with no
/// card in hand: the page's own bands in skeleton, in its own order and rhythm. Two dish rows parted
/// by a hairline, three lines of words, and the place line under its rule.
struct EntryPageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.pageBandGap) {
            VStack(alignment: .leading, spacing: 0) {
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
                AteSkeletonBar(height: 14)
                AteSkeletonBar(width: 190, height: 14)
            }
            .padding(.vertical, 4)
            VStack(spacing: 0) {
                AteHairline()
                HStack {
                    AteSkeletonBar(width: 150, height: 14)
                    Spacer(minLength: 0)
                    AteSkeletonBar(width: 70, height: 12)
                }
                .frame(minHeight: AteMetrics.hit)
            }
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("entry.skeleton")
    }
}
