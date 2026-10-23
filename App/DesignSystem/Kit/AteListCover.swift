import AteKit
import SwiftUI

/// **A list's cover** (`lists-playlists.html`, approved 9 Oct) — a list drawn as a playlist of
/// dishes. Square, at the kit's 16 radius, straight (a cover is a picture of the list, not a mess):
/// four or more photos make a 2×2 mosaic of the first four, fewer show the first one whole, and none
/// is the list's own accent with its name set on it in Young Serif, ink in both modes.
///
/// A cover the owner picked (`list-cover-edit.html`) shows whole instead of the mosaic. A list someone
/// shared with you carries their photo in its top corner (screen 8); the name and count under it stay
/// exactly as on your own lists.
struct AteListCover: View {
    enum Style: Equatable {
        /// A tile on the shelf's grid: as wide as its column.
        case tile
        /// The head of the list's own page: 224, lifted.
        case hero
        /// A choice on the Change cover sheet (`list-cover-sheet.html` A): the dish row's 56, flat; with
        /// no photos, only its colour (the name has no room).
        case row
    }

    let id: UUID
    let name: String
    /// The list's photos, in list order (``AteKit/UserList/covers``, at most four).
    var covers: [String] = []
    /// The picked cover (``AteKit/UserList/coverURL``); `nil` is the automatic mosaic.
    var cover: String?
    /// A photo just squared up in the cover sheet, before it has uploaded: it wins over everything.
    var image: UIImage?
    /// Whose list it is, when it is not yours.
    var owner: ListPerson?
    /// Set by the shelf so neighbours never share a colour; `nil` is the list's own.
    var accentIndex: Int?
    var style: Style = .tile

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(width: width)
            .overlay { art }
            .clipShape(shape)
            .ateBackground(palette.field, in: shape, shadow: style == .hero ? .cover : .flat)
            .overlay(alignment: .topLeading) {
                if let owner, style == .tile {
                    AteAvatar(
                        userID: owner.id, handle: owner.username, side: AteListCoverMetrics.ownerSide,
                        url: owner.avatarURL.flatMap(URL.init(string:))
                    )
                    .overlay { Circle().strokeBorder(AteColor.overPhoto, lineWidth: AteListCoverMetrics.ownerRing) }
                    .ateShadow(.badge)
                    .padding(AteListCoverMetrics.ownerInset)
                }
            }
            .accessibilityHidden(true)
    }

    private var width: CGFloat? {
        switch style {
        case .tile: nil
        case .hero: AteListCoverMetrics.hero
        case .row: AteListCoverMetrics.row
        }
    }

    @ViewBuilder
    private var art: some View {
        let photos = covers.map { AtePhoto.remote($0) }
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let cover {
            AtePhotoContent(photo: .remote(cover), size: style == .row ? .thumbnail : .large)
        } else if photos.count >= AteListCoverMetrics.mosaic {
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
            AtePhotoContent(photo: first, size: style == .row ? .thumbnail : .large)
        } else if style == .row {
            accent
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
    var cover: String?
    var owner: ListPerson?
    /// Still being made: drawn, not yet a door.
    var isPending = false
    var accentIndex: Int?
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AteListCoverMetrics.captionGap) {
                AteListCover(id: id, name: name, covers: covers, cover: cover, owner: owner, accentIndex: accentIndex)
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
        .accessibilityLabel(owner.map { "\(name), @\($0.username)'s list" } ?? name)
        .accessibilityValue(ListTileCopy.dishes(count))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier ?? "list.tile")
    }
}

/// **New list, as the shelf's last tile** — a dashed square with the plus, "New list" under it.
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

/// A tile while the shelf loads: the cover's square in the field colour, under the paper feed.
struct AteListTileSkeleton: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous)
            .fill(palette.field)
            .aspectRatio(1, contentMode: .fit)
            .ateSkeletonSweep()
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
    /// A cover choice's picture: the dish row's 56.
    static let row: CGFloat = 56
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
    /// A shared list's owner: `.owner{top:8px;left:8px;width:28px}` with a 2pt white ring.
    static let ownerSide: CGFloat = 28
    static let ownerInset: CGFloat = 8
    static let ownerRing: CGFloat = 2
}
