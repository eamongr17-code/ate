import AteKit
import SwiftUI
import TipKit

/// **The hero card** — The Top Ate's first dish as a photo: the column's width × 330 at radius 16, a
/// shade rising from its foot, the score token (hero size) top left and the glass bookmark disc top
/// right, 12 in, and the dish over its place in white at the foot, two lines at most. **No rank
/// numeral.**
///
/// With no photo the card is the dish's letter tile: its accent ground with no shade, the letter
/// optically centred in the space above the caption — never behind it — and the caption in ink, as
/// every accent carries.
struct AteHeroCard: View {
    let photo: AtePhoto
    let name: String
    var place: String?
    var score: AteScore?
    var isSaved = false
    var onOpen: (() -> Void)?
    var onSave: (() -> Void)?
    /// A tip on the bookmark — the Feed's Save tip, on its first dish.
    var saveTip: (any Tip)?

    var body: some View {
        Button { onOpen?() } label: {
            face
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
                    .popoverTip(saveTip, arrowEdge: .top)
                    .padding(AteHeroCardMetrics.inset)
            }
        }
    }

    /// The tile behind the caption: the photo under its shade, or the letter on its accent.
    @ViewBuilder
    private var face: some View {
        let metrics = AteThumbMetrics(.hero)
        if photo.image == nil, photo.url == nil, let dish = photo.dish {
            VStack(spacing: 0) {
                Text(dish.letter)
                    .ateText(.kitThumbInitial(metrics.initial))
                    .foregroundStyle(AteColor.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                caption(ink: AteColor.ink, muted: AteColor.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.height)
            .background(dish.accent)
        } else {
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
                .overlay(alignment: .bottomLeading) {
                    caption(ink: AteKitColor.overPhoto, muted: AteKitColor.overPhotoMuted)
                }
        }
    }

    private func caption(ink: Color, muted: Color) -> some View {
        VStack(alignment: .leading, spacing: AteHeroCardMetrics.lineGap) {
            Text(name)
                .ateText(.kitHeroDish)
                .foregroundStyle(ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let place {
                Text(place)
                    .ateText(.kitHeroPlace)
                    .foregroundStyle(muted)
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
