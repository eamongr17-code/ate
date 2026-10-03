import AteKit
import SwiftUI

/// **The hero card** — The Top Ate's first dish as a photo: the column's width × 330 at radius 16, a
/// shade rising from its foot, the score token (hero size) top left and the glass bookmark disc top
/// right, 12 in, and the dish over its place in white at the foot. **No rank numeral.**
struct AteHeroCard: View {
    let photo: AtePhoto
    let name: String
    var place: String?
    var score: AteScore?
    var isSaved = false
    var onOpen: (() -> Void)?
    var onSave: (() -> Void)?

    var body: some View {
        Button { onOpen?() } label: {
            AteThumb(photo: photo, size: .hero)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: AteKitColor.heroShadeTop, location: AteKitColor.heroShadeStart),
                            .init(color: AteKitColor.heroShadeFoot, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .bottomLeading) { caption }
                .clipShape(RoundedRectangle(cornerRadius: AteThumbMetrics(.hero).radius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hero.open")
        .overlay(alignment: .topLeading) {
            AteScoreToken(score, size: .hero)
                .padding(AteHeroCardMetrics.inset)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if let onSave {
                AteSaveButton(dishName: name, isSaved: isSaved, identifier: "hero.save",
                              style: .glass(.hero), action: onSave)
                    .padding(AteHeroCardMetrics.inset)
            }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: AteHeroCardMetrics.lineGap) {
            Text(name)
                .ateText(.kitHeroDish)
                .foregroundStyle(AteKitColor.overPhoto)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let place {
                Text(place)
                    .ateText(.kitHeroPlace)
                    .foregroundStyle(AteKitColor.overPhotoMuted)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, AteHeroCardMetrics.captionLift)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AteHeroCardMetrics.captionInset)
    }
}

enum AteHeroCardMetrics {
    /// The token and the disc: `left/right:12px; top:12px`.
    static let inset: CGFloat = 12
    /// The caption: `left/right/bottom:16px`, `.nm{gap:5px; padding-bottom:4px}`.
    static let captionInset: CGFloat = 16
    static let lineGap: CGFloat = 5
    static let captionLift: CGFloat = 4
}
