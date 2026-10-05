import AteKit
import SwiftUI

/// **A list on the shelf** (`lists-notifications.html` §3, "Colour-blocked cards", approved) — a
/// full-width card at the kit's 16 radius in the list's own accent, picked from its id like an
/// avatar's (never butter, which is a score; never coral, the share ground). Across the top, the
/// count and up to three of the list's photos as a small tilted cluster ringed in the card's
/// colour; at the foot, the name in Bricolage 800, two lines at most. Ink lettering in both modes,
/// the accent undimmed in dark.
struct AteListCard: View {
    let id: UUID
    let name: String
    let count: Int
    /// The list's photos, in list order — the first three are drawn.
    var covers: [String] = []
    /// Still being made: drawn, not yet a door.
    var isPending = false
    var identifier: String?
    let action: () -> Void

    var body: some View {
        let accent = Self.accent(for: id)
        Button(action: action) {
            VStack(alignment: .leading, spacing: AteListCardMetrics.gap) {
                HStack(alignment: .top, spacing: AteMetrics.snug) {
                    Text(count == 1 ? "1 dish" : "\(count) dishes")
                        .ateText(.kitListCardCount)
                        .opacity(AteListCardMetrics.countOpacity)
                        .padding(.top, AteListCardMetrics.countTop)
                    Spacer(minLength: 0)
                    if covers.isEmpty == false {
                        PhotoCluster(
                            photos: covers.prefix(AteListCardMetrics.photos).compactMap(URL.init(string:))
                                .map { AtePhoto(url: $0) },
                            side: AteListCardMetrics.photo,
                            surface: accent,
                            topPadding: 0,
                            bottomPadding: 0,
                            angles: AtePhotoAngles.slip
                        )
                        .allowsHitTesting(false)
                    }
                }
                Spacer(minLength: 0)
                Text(name)
                    .ateText(.kitListCardName)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: AteListCardMetrics.nameWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AteColor.ink)
            .padding(.top, AteListCardMetrics.padding)
            .padding(.bottom, AteListCardMetrics.padding)
            .padding(.leading, AteListCardMetrics.leading)
            .padding(.trailing, AteListCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: AteListCardMetrics.height, alignment: .topLeading)
            .background(accent, in: .rect(cornerRadius: AteListCardMetrics.radius, style: .continuous))
            .contentShape(.rect(cornerRadius: AteListCardMetrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(count == 1 ? "1 dish" : "\(count) dishes")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "list.card")
    }

    /// The card's colour: the letter tiles' accents less butter and coral, picked from the id so
    /// a list keeps its colour across launches and devices.
    static func accent(for id: UUID) -> Color {
        accents[DishTileIdentity.paletteIndex(for: id, count: accents.count)]
    }

    static let accents: [Color] = [AteColor.green, AteColor.lilac, AteColor.sky, AteColor.pink]
}

/// A list card while the shelf loads: the card's own silhouette in the field colour, breathing.
struct AteListCardSkeleton: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: AteListCardMetrics.radius, style: .continuous)
            .fill(palette.field)
            .frame(maxWidth: .infinity)
            .frame(height: AteListCardMetrics.height)
            .ateBreathing()
            .accessibilityHidden(true)
    }
}

enum AteListCardMetrics {
    /// `.lc{border-radius:16px; height:168px; padding:16px 16px 16px 18px}`.
    static let radius: CGFloat = 16
    static let height: CGFloat = 168
    static let padding: CGFloat = 16
    static let leading: CGFloat = 18
    /// `.lc .ct{opacity:.72; padding-top:4px}`.
    static let countOpacity: Double = 0.72
    static let countTop: CGFloat = 4
    /// `.lc .nm{max-width:300px}`.
    static let nameWidth: CGFloat = 300
    /// The cluster: three photos at 58, `rotate(-5 4 -2)`.
    static let photo: CGFloat = 58
    static let photos = 3
    /// Between the top row and the name, at the least.
    static let gap: CGFloat = 12
    /// Between cards on the shelf: `.lcs{gap:12px}`.
    static let spacing: CGFloat = 12
}
