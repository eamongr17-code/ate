import AteKit
import SwiftUI

/// **Welcome's printed slip** — two photos together in a tilted cluster, clear **above** the receipt
/// (never on it), then the slip itself, tilted: the wordmark, "A record of everything worth
/// ordering.", a dashed rule and "Made to order". No barcode (cut 3 Oct). Drawn on the coral ground,
/// so the photos' ring is coral.
struct AteWelcomeCard: View {
    /// Made once, so the same two photos keep their identity across redraws.
    @State private var photos = AteWelcomeCardMetrics.photos.map { AtePhoto(image: Image($0)) }

    var body: some View {
        VStack(spacing: AteWelcomeCardMetrics.photosToSlip) {
            PhotoCluster(
                photos: photos,
                side: AteWelcomeCardMetrics.photo,
                surface: AteColor.coral,
                topPadding: 0,
                bottomPadding: 0,
                overlap: AteWelcomeCardMetrics.overlap,
                angles: AteWelcomeCardMetrics.angles
            )
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            paper
                .rotationEffect(.degrees(AteWelcomeCardMetrics.slipAngle))
                .padding(.horizontal, AteWelcomeCardMetrics.slipInset)
        }
    }

    private var paper: some View {
        VStack(spacing: AteWelcomeCardMetrics.paperGap) {
            AteWordmark(height: AteWelcomeCardMetrics.wordmark)
            Text("A record of everything\nworth ordering.")
                .ateText(.proseQuote)
                .multilineTextAlignment(.center)
            AteDashedRule()
            Text("Made to order")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.slip.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AteWelcomeCardMetrics.paperTop)
        .padding(.horizontal, AteWelcomeCardMetrics.paperSide)
        .padding(.bottom, AteWelcomeCardMetrics.paperSide + AteMetrics.tornEdgeHeight)
        // The receipt palette, like every receipt Ate prints: white in light, the plum slip in dark.
        .ateSlip()
        .ateTornPaper()
    }
}

/// **Welcome's quiet way in** — "See what everyone's eating" (or "Not now" when Welcome is the
/// sign-in ask), ink on the coral, with the hairline under it the markup draws. The one underlined
/// line in the app, kept from the build.
struct AteWelcomeLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ateText(.control)
                .multilineTextAlignment(.center)
                .padding(.bottom, AteMetrics.hairspace)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AteColor.ink).frame(height: AteWelcomeCardMetrics.underline)
                }
                .frame(minHeight: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AteColor.ink)
        .accessibilityIdentifier("welcome.browse")
    }
}

enum AteWelcomeCardMetrics {
    /// The build's two photos, `132` each, `-8` and `6`.
    static let photos = ["Photos/pizza", "Photos/burger"]
    static let photo: CGFloat = 132
    static let angles: [Double] = [-8, 6]
    static let overlap: CGFloat = 20
    static let photosToSlip: CGFloat = 28
    /// `left:50px; right:50px`, `rotate(-2.5deg)`.
    static let slipInset: CGFloat = 50
    static let slipAngle: Double = -2.5
    /// `padding:30px 18px 18px; gap:14px`.
    static let paperTop: CGFloat = 30
    static let paperSide: CGFloat = 18
    static let paperGap: CGFloat = 14
    static let wordmark: CGFloat = 96
    static let underline: CGFloat = 1
    /// `left:20; right:20; bottom:40; gap:6` — Apple's button, then the link.
    static let doorsGap: CGFloat = 6
    static let doorsBottom: CGFloat = 40
}
