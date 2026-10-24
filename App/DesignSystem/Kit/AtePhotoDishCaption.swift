import SwiftUI

/// **Which dish a photo is.** In the viewer, bottom-left over a soft scrim: the dish, then who and
/// where (design/rebuild/photo-dish-caption.html, B; Eamon, 15 Oct). A caption, not a pill, so
/// nothing reads as a button. Your own photo is captioned the same way, with a faint pencil at the
/// right to fix the dish (``AtePhotoDishPill``; own-photo-caption.html, A; Eamon, 24 Oct).
struct AtePhotoDishCaption: View {
    /// Empty: no dish yet (your own photo, before you pick one), so the byline alone.
    let dish: String
    /// "@paris · 400 Gradi". `nil`: the dish alone.
    var byline: String?
    /// Your own photo's pencil.
    var edit: AtePhotoDishPill?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AtePhotoDishCaptionMetrics.gap) {
                if dish.isEmpty == false {
                    Text(dish)
                        .ateTextExactLifted(.kitPhotoCaptionDish)
                        .lineLimit(2)
                }
                if let byline, byline.isEmpty == false {
                    Text(byline)
                        .ateText(.kitPhotoCaptionByline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(AtePhotoDishCaptionMetrics.bylineOpacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("photo.dish")
            if let edit {
                edit
            }
        }
        .foregroundStyle(AteColor.overPhoto)
        .padding(.leading, AtePhotoDishCaptionMetrics.leading)
        .padding(.trailing, edit == nil ? AtePhotoDishCaptionMetrics.leading : AtePhotoDishCaptionMetrics.editTrailing)
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
    }
}

enum AtePhotoDishCaptionMetrics {
    static let gap: CGFloat = 2
    static let leading: CGFloat = 20
    /// The pencil's 44pt target sits this far in, so its glyph lines up with the close button's.
    static let editTrailing: CGFloat = 4
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
        VStack(spacing: 0) {
            AtePhotoDishCaption(dish: "Margherita", byline: "@paris · 400 Gradi")
            AtePhotoDishCaption(
                dish: "Chinese Mala Chicken Burger", byline: "@eamon · Chop Chop",
                edit: AtePhotoDishPill(dishes: [], choices: [.init(id: UUID(), name: "Chinese Mala Chicken Burger")],
                                       onPick: { _ in })
            )
        }
    }
}
#endif
