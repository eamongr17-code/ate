import SwiftUI

/// **The logo.** Design rule 11: it is the supplied wordmark, never typeset — so there is no code
/// path anywhere that draws "ate" as text.
///
/// The asset is a template-rendered vector, so it takes the foreground colour of wherever it is put:
/// ink on the linen ground, white on the ink ground, ink again on a receipt's paper. One asset, three
/// correct results, no variants.
struct AteWordmark: View {
    /// Cap height in points. The design uses 30 on a screen header and 18 in a receipt's footer.
    var height: CGFloat = AteMetrics.wordmarkHeader

    /// The supplied artwork's aspect (758 × 359).
    private static let aspect: CGFloat = 758.0 / 359.0

    @Environment(\.atePalette) private var palette

    var body: some View {
        Image(.ateWordmark)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: (height * Self.aspect).rounded(), height: height)
            .foregroundStyle(palette.fg)
            .accessibilityLabel("Ate")
    }
}

#if DEBUG
#Preview("Wordmark") {
    VStack(spacing: AteMetrics.section) {
        AteWordmark()
        AteWordmark(height: AteMetrics.wordmarkFooter)
        AteWordmark(height: 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ateGround()
}
#endif
