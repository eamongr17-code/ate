import SwiftUI

/// **The reviews, on one whole slip** (`dish-page-place-map.html`, A): "Reviews" over yours and the
/// star bands, so the page reads as parts rather than loose rows on the ground.
struct V2ReviewsCard<Rows: View>: View {
    @ViewBuilder var rows: Rows

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteMetrics.slipCorner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(V2DishCopy.reviews)
                .ateText(.feedSection)
                .foregroundStyle(AtePalette.slip.fg)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, AteMetrics.loose)
                .padding(.bottom, AteMetrics.tight)
            rows
        }
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { shape.fill(AtePaperTone.slip.fill).ateContactLine(.slip) }
        .ateSlip()
        .padding(.horizontal, AteMetrics.listGutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dish.reviews")
    }
}

enum V2DishCopy {
    static let reviews = "Reviews"
}
