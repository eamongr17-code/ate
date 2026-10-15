#if DEBUG || BETA
import AteKit
import SwiftUI

/// **Share** (11 Oct, approved): the receipt on its stage, the ink share sheet's three cards and its
/// row.
extension KitGalleryScreen {
    @ViewBuilder
    var share: some View {
        section("Printed receipt") {
            VStack(spacing: AteMetrics.section) {
                AtePrintedReceiptStage(receipt: .preview, photos: Array(AtePhoto.swatches.prefix(2)))
                AtePrintedReceiptStage(receipt: .previewSingle)
            }
            .padding(.vertical, AteMetrics.section)
            .frame(maxWidth: .infinity)
            .ateAccentGround(AteColor.coral)
        }
        section("Share cards") {
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: AteMetrics.regular) {
                    AteShareCard(format: .sticker, receipt: .preview, look: AteShareLook(paper: .butter))
                    AteShareCardPreview(
                        card: AteShareCard(format: .story, receipt: .preview, look: AteShareLook(ground: .coral)),
                        width: V2ShareSheetMetrics.width(.story)
                    )
                    AteShareCardPreview(
                        card: AteShareCard(format: .post, receipt: .preview), width: V2ShareSheetMetrics.width(.post)
                    )
                }
                .padding(AteMetrics.gutter)
            }
            .scrollIndicators(.hidden)
            .background(AteColor.ink)
        }
        section("Share to, on the ink sheet") {
            AteShareRow(actions: [
                .init(id: "stories", icon: .instagram, title: "Stories", brand: .instagram) {},
                .init(id: "tiktok", icon: .tiktok, title: "TikTok", brand: .tiktok) {},
                .init(id: "messages", icon: .messageCircle, title: "Messages", brand: .messages) {},
                .init(id: "instagram", icon: .instagram, title: "Instagram", brand: .instagram) {},
                .init(id: "link", icon: .link, title: "Copy link") {},
                .init(id: "save", icon: .download, title: "Save image") {},
                .init(id: "more", icon: .more, title: "More") {}
            ])
            .padding(.vertical, AteMetrics.section)
            .environment(\.atePalette, .ink)
            .background(AteColor.ink)
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
}
#endif
