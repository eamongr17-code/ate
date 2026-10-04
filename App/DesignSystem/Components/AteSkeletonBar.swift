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
