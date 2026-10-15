import SwiftUI

/// **Which dish somebody else's photo is.** In the viewer, bottom-left over a soft scrim: the dish,
/// then who and where (design/rebuild/photo-dish-caption.html, B; Eamon, 15 Oct). A caption, not a
/// pill: there is nothing to tap on another person's entry, so nothing should look like a button.
/// Your own entry keeps ``AtePhotoDishPill``, which is a menu to fix the dish.
struct AtePhotoDishCaption: View {
    let dish: String
    /// "@paris · 400 Gradi". `nil`: the dish alone.
    var byline: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AtePhotoDishCaptionMetrics.gap) {
            Text(dish)
                .ateText(.kitPhotoCaptionDish)
                .lineLimit(2)
            if let byline, byline.isEmpty == false {
                Text(byline)
                    .ateText(.kitPhotoCaptionByline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(AtePhotoDishCaptionMetrics.bylineOpacity)
            }
        }
        .foregroundStyle(AteColor.overPhoto)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AtePhotoDishCaptionMetrics.leading)
        .padding(.bottom, AtePhotoDishCaptionMetrics.bottom)
        .padding(.top, AtePhotoDishCaptionMetrics.scrimLead)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [AteColor.viewerGround.opacity(AtePhotoDishCaptionMetrics.scrimOpacity), .clear],
                startPoint: .bottom, endPoint: .top
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photo.dish")
    }
}

enum AtePhotoDishCaptionMetrics {
    static let gap: CGFloat = 2
    static let leading: CGFloat = 20
    /// Above the page dots and the home indicator — the pill's line.
    static let bottom: CGFloat = 44
    /// How far the scrim reaches above the caption (`.scrim` is 170 tall).
    static let scrimLead: CGFloat = 80
    static let scrimOpacity: Double = 0.7
    static let bylineOpacity: Double = 0.75
}

/// What the caption prints under the dish: who, then where, either one alone, or nothing.
enum AtePhotoDishByline {
    static func line(who: String?, place: String?) -> String? {
        let parts = [who, place].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Photo dish caption") {
    ZStack(alignment: .bottom) {
        AteColor.viewerGround.ignoresSafeArea()
        AtePhotoDishCaption(dish: "Margherita", byline: "@paris · 400 Gradi")
    }
}
#endif
