#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Share** (10 Oct, approved): the sticker, a dish tag, the three story pages and the row.
extension KitGalleryScreen {
    @ViewBuilder
    var share: some View {
        section("Share sticker") {
            VStack(spacing: AteMetrics.section) {
                AteShareSlip(receipt: .preview)
                AteShareSlip(receipt: .previewSingle)
                AteDishTag(name: "Tagliatelle al ragù", score: Rating(rounding: 4.5))
                AteDishTag(name: "Prawn spaghetti")
            }
            .padding(.vertical, AteMetrics.section)
            .frame(maxWidth: .infinity)
            .ateAccentGround(AteColor.coral)
        }
        section("Story pages") {
            ScrollView(.horizontal) {
                HStack(spacing: AteMetrics.regular) {
                    storyPage(AteShareStory(sticker: .photo, receipt: .preview, photo: AtePhoto.swatches.first))
                    storyPage(AteShareStory(sticker: .slip, receipt: .preview))
                    storyPage(AteShareStory(
                        sticker: .dish, receipt: .preview, photo: AtePhoto.swatches.dropFirst().first,
                        dish: AteReceipt.preview.items.first
                    ))
                }
                .padding(.horizontal, AteMetrics.gutter)
            }
            .scrollIndicators(.hidden)
        }
        section("Share to") {
            AteShareRow(actions: [
                .init(id: "stories", icon: .camera, title: "Instagram Stories", isPrimary: true) {},
                .init(id: "link", icon: .link, title: "Copy link") {},
                .init(id: "messages", icon: .messageCircle, title: "Messages") {},
                .init(id: "save", icon: .download, title: "Save image") {},
                .init(id: "more", icon: .more, title: "More") {}
            ])
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.vertical, AteMetrics.section)
            .ateAccentGround(AteColor.coral)
        }
    }

    /// A story page at half size.
    private func storyPage(_ story: AteShareStory) -> some View {
        AteScaledLayout(scale: KitShareMetrics.pageScale) {
            story.scaleEffect(KitShareMetrics.pageScale)
        }
        .clipShape(RoundedRectangle(cornerRadius: AteShareStoryMetrics.radius, style: .continuous))
    }
}

private enum KitShareMetrics {
    static let pageScale: CGFloat = 0.5
}
#endif
