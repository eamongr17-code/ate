import SwiftUI

/// **A list's cover** (`lists-playlists.html`, approved 9 Oct) — a list drawn as a playlist of
/// dishes. Square, at the kit's 16 radius, straight (a cover is a picture of the list, not a mess):
/// four or more photos make a 2×2 mosaic of the first four, fewer show the first one whole, and none
/// is the list's own accent with its name set on it in Bricolage 800, ink in both modes.
struct AteListCover: View {
    enum Style: Equatable {
        /// A tile on the shelf's grid: as wide as its column.
        case tile
        /// The head of the list's own page: 224, lifted.
        case hero
    }

    let id: UUID
    let name: String
    /// The list's photos, in list order (``AteKit/UserList/covers``, at most four).
    var covers: [String] = []
    /// Set by the shelf so neighbours never share a colour; `nil` is the list's own.
    var accentIndex: Int?
    var style: Style = .tile

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(width: style == .hero ? AteListCoverMetrics.hero : nil)
            .overlay { art }
            .clipShape(shape)
            .ateBackground(palette.field, in: shape, shadow: style == .hero ? .cover : .flat)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var art: some View {
        let photos = covers.map { AtePhoto.remote($0) }
        if photos.count >= AteListCoverMetrics.mosaic {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    quarter(photos[0])
                    quarter(photos[1])
                }
                HStack(spacing: 0) {
                    quarter(photos[2])
                    quarter(photos[3])
                }
            }
        } else if let first = photos.first {
            AtePhotoContent(photo: first, size: .large)
        } else {
            named
        }
    }

    private func quarter(_ photo: AtePhoto) -> some View {
        Color.clear
            .overlay { AtePhotoContent(photo: photo, size: style == .hero ? .large : .thumbnail) }
            .clipped()
    }

    private var named: some View {
        Text(name)
            .ateText(style == .hero ? .kitListCoverNameHero : .kitListCoverName)
            .foregroundStyle(AteColor.ink)
            .lineLimit(style == .hero ? 4 : 3)
            .minimumScaleFactor(AteListCoverMetrics.nameScale)
            .multilineTextAlignment(.leading)
            .padding(style == .hero ? AteListCoverMetrics.heroInset : AteListCoverMetrics.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(accent)
    }

    private var accent: Color {
        accentIndex.map { Self.accents[$0 % Self.accents.count] } ?? Self.accent(for: id)
    }

    /// The cover's colour with no photo: the letter tiles' accents less butter (a score) and coral
    /// (the share ground), picked from the id so a list keeps its colour across launches and devices.
    static func accent(for id: UUID) -> Color {
        accents[DishTileIdentity.paletteIndex(for: id, count: accents.count)]
    }

    static let accents: [Color] = [AteColor.green, AteColor.lilac, AteColor.sky, AteColor.pink]
}

/// **A list on the shelf** — its cover, then the name (two lines at most) and the count under it.
struct AteListTile: View {
    let id: UUID
    let name: String
    let count: Int
    var covers: [String] = []
    /// Still being made: drawn, not yet a door.
    var isPending = false
    var accentIndex: Int?
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AteListCoverMetrics.captionGap) {
                AteListCover(id: id, name: name, covers: covers, accentIndex: accentIndex)
                Text(name)
                    .ateText(.kitListTileName)
                    .foregroundStyle(palette.fg)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, AteListCoverMetrics.nameTop)
                Text(ListTileCopy.dishes(count))
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(ListTileCopy.dishes(count))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "list.tile")
    }
}

/// **New list, as the shelf's first tile** — a dashed square with the plus, "New list" under it.
struct AteNewListTile: View {
    let title: String
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AteListCoverMetrics.captionGap) {
                RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous)
                    .strokeBorder(palette.hairline, style: StrokeStyle(
                        lineWidth: AteListCoverMetrics.dash, dash: AteListCoverMetrics.dashPattern
                    ))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { AteIcon.compose.view(size: AteListCoverMetrics.plus).foregroundStyle(palette.muted) }
                Text(title)
                    .ateText(.kitListTileName)
                    .foregroundStyle(palette.fg)
                    .padding(.top, AteListCoverMetrics.nameTop)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "list.newTile")
    }
}

/// A tile while the shelf loads: the cover's square in the field colour, breathing.
struct AteListTileSkeleton: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous)
            .fill(palette.field)
            .aspectRatio(1, contentMode: .fit)
            .ateBreathing()
            .accessibilityHidden(true)
    }
}

private enum ListTileCopy {
    static func dishes(_ count: Int) -> String {
        count == 1 ? "1 dish" : "\(count) dishes"
    }
}

enum AteListCoverMetrics {
    /// `.cov{border-radius:16px}`; the hero `width:224px`.
    static let radius: CGFloat = 16
    static let hero: CGFloat = 224
    /// Four photos or more make the mosaic.
    static let mosaic = 4
    /// `.cov.gen{padding:12px}`, and 18 on the hero.
    static let inset: CGFloat = 12
    static let heroInset: CGFloat = 18
    /// A long name shrinks to fit before it truncates.
    static let nameScale: CGFloat = 0.7
    /// `.tile{gap:7px}`, `.tile .mt{margin-top:-4px}` — the name sits 7 under the cover, the count 3
    /// under the name.
    static let captionGap: CGFloat = 3
    static let nameTop: CGFloat = 4
    /// `.newcov{border:2px dashed}`, and its plus.
    static let dash: CGFloat = 2
    static let dashPattern: [CGFloat] = [6, 5]
    static let plus: CGFloat = 34
    /// `.grid{gap:20px 14px; left:16px; right:16px}`.
    static let columnGap: CGFloat = 14
    static let rowGap: CGFloat = 20
    static let gutter: CGFloat = 16
}
