import AteKit
import SwiftUI

/// A photo, or the space held for one. `image == nil` is a photo that hasn't loaded yet — never an
/// error state and never a spinner (design: skeletons of the real component, not spinners).
struct AtePhoto: Identifiable, Equatable {
    let id: UUID
    var image: Image?
    /// A photo that lives on the server. Loaded by the tile itself, so a caller never has to hold an
    /// image cache — and a photo still arriving holds its space rather than collapsing the cluster.
    var url: URL?
    /// Set where the photo is **a dish's** thumbnail: with no photo, or one that will not load, the
    /// tile is the dish's letter on its own accent (`NoPhotoA`) — never an empty grey square.
    var dish: DishLetter?

    init(id: UUID = UUID(), image: Image? = nil, url: URL? = nil, dish: DishLetter? = nil) {
        self.id = id
        self.image = image
        self.url = url
        self.dish = dish
    }

    /// A photo on the server, named by its address — so the same photo is the same tile on every
    /// redraw, and a card re-rendering around it (a bookmark flipping) never reloads it.
    static func remote(_ address: String) -> AtePhoto {
        AtePhoto(id: PhotoAddress.stableID(for: address), url: URL(string: address))
    }

    /// A dish's thumbnail: its cover, or its letter tile.
    static func dish(_ dishID: UUID, name: String, cover: String?) -> AtePhoto {
        AtePhoto(id: dishID, url: cover.flatMap(URL.init(string:)), dish: DishLetter(dishID: dishID, name: name))
    }
}

/// **The letter tile** (`NoPhotoA.dc.html`, 2026-09-26): what a dish with no photo shows wherever a
/// dish thumbnail appears — the slot keeps its shape, filled with one accent and the dish's first
/// letter in Bricolage 800 (26 on a 56 tile), ink on it like every accent. The accent is the dish's:
/// picked from its id (``DishTileIdentity/paletteIndex(for:count:)``, stable across launches), and
/// **never butter**, which means a score.
struct DishLetter: Equatable, Sendable {
    let dishID: UUID
    let name: String

    /// Coral, green, pink, sky, lilac — the accents less butter.
    static let accents: [Color] = [AteColor.coral, AteColor.green, AteColor.pink, AteColor.sky, AteColor.lilac]

    var accent: Color { Self.accents[DishTileIdentity.paletteIndex(for: dishID, count: Self.accents.count)] }
    var letter: String { DishTileIdentity.initial(for: name) }
}

struct DishLetterTile: View {
    let dish: DishLetter

    var body: some View {
        GeometryReader { proxy in
            Text(dish.letter)
                .ateText(.dishInitial(tile: min(proxy.size.width, proxy.size.height)))
                .foregroundStyle(AteColor.ink)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(dish.accent)
        .accessibilityHidden(true)
    }
}

/// A squircle photo: radius is 28% of the side, so the shape reads the same at 80pt and at 128pt.
/// (The entry collage names its own corners — 30/28/24 on 200/184/140 — and draws its own tiles.)
struct AtePhotoTile: View {
    let photo: AtePhoto
    let side: CGFloat
    /// The ring that separates overlapping photos, drawn in the colour of the surface behind them.
    var ring: Color?

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous)
        return AtePhotoContent(photo: photo, size: .forSide(side))
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay {
            // `box-shadow:0 0 0 3px var(--surface)` — the ring sits entirely OUTSIDE the photo, so
            // the white parting between two overlapping tiles is a full 3pt, not half of one.
            if let ring {
                shape.strokeBorder(ring, lineWidth: AteMetrics.photoRing)
                    .padding(-AteMetrics.photoRing)
            }
        }
        .accessibilityHidden(true)
    }
}

/// What actually fills a tile: a picked image, a photo coming down the wire, or the space it will
/// take. Never a spinner and never a shimmer — a still tile in the surface's field colour, which the
/// picture fades into (``AteRemotePhoto``).
///
/// `.fill` everywhere a photo is a tile; `.fit` in the full-screen viewer, which is the one place the
/// whole photo is the point.
struct AtePhotoContent: View {
    let photo: AtePhoto
    var contentMode: ContentMode = .fill
    /// How much of the photo to fetch and decode — a list's squircle asks for the thumbnail.
    var size: AtePhotoSize = .large

    @Environment(\.atePalette) private var palette

    var body: some View {
        if let image = photo.image {
            image.resizable().aspectRatio(contentMode: contentMode)
        } else if let url = photo.url {
            AteRemotePhoto(url: url, size: size, contentMode: contentMode, failure: photo.dish)
        } else if let dish = photo.dish {
            DishLetterTile(dish: dish)
        } else {
            palette.field
        }
    }
}

/// **The mess.** Design rule 6: photos tilt and overlap *only* in small static clusters — the entry
/// page, a dish hero, the share card, welcome. Anything in a scrolling list is straight and evenly
/// spaced, which is why the tilt lives in this component and not in the tile.
///
/// The angles are fixed per position rather than random, so the same entry always looks the same —
/// a cluster that re-shuffles every time the list scrolls past is noise, not character.
struct PhotoCluster: View {
    let photos: [AtePhoto]
    var side: CGFloat = AteMetrics.clusterPhoto
    /// The colour directly behind the cluster — the ring that separates overlapping photos is drawn
    /// in it, so it has to be the real surface: the ground on a journal slip, the control surface in
    /// the composer, the accent on a share card.
    var surface: Color?
    /// The air the artboard leaves around a cluster. The composer's is `4px 0 2px 6px`, a slip's is
    /// `2px 0 0 6px` — small numbers, but they are the difference between a photo that sits on the
    /// words and one that sits on the paper's edge.
    var topPadding: CGFloat = AteMetrics.tight
    var bottomPadding: CGFloat = AteMetrics.hairspace
    /// How far the tiles overlap. 12 in a slip's 80pt cluster; the dish page's hero is 150pt and
    /// laps 44, because an overlap is a fraction of the photo and not an absolute.
    var overlap: CGFloat = AteMetrics.clusterOverlap
    /// The tilt, per position. Defaults to ``AtePhotoAngles/slip`` — a slip's, the composer's and
    /// the share card's cluster. **Parity is per artboard**, so a screen whose markup writes
    /// different numbers passes its own (the dish hero's ``AtePhotoAngles/dishHero``) rather than
    /// forking the component or living with a degree of drift.
    var angles: [Double] = AtePhotoAngles.slip
    /// Set where a photo can be taken back out (the composer): a long press on it offers the
    /// system's own menu with one destructive item.
    var onRemove: ((Int) -> Void)?
    /// A photo was tapped — the full-screen viewer, opened on it. `nil` leaves the cluster a picture.
    var onTap: ((Int) -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        let cluster = HStack(spacing: -overlap) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                tile(photo, at: index)
                    .zIndex(Double(photos.count - index))
            }
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        // Every artboard insets a cluster by 6 on the leading edge, so the first photo's tilt has
        // somewhere to go.
        .padding(.leading, 6)

        if onTap == nil {
            cluster
                .accessibilityElement()
                .accessibilityLabel(photos.count == 1 ? "1 photo" : "\(photos.count) photos")
                .accessibilityActions {
                    if let onRemove {
                        ForEach(photos.indices, id: \.self) { index in
                            Button("Remove photo \(index + 1)") { onRemove(index) }
                        }
                    }
                }
        } else {
            cluster.accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func tile(_ photo: AtePhoto, at index: Int) -> some View {
        let drawn = AtePhotoTile(
            photo: photo,
            side: side,
            ring: photos.count > 1 ? (surface ?? palette.ground) : nil
        )
        .rotationEffect(.degrees(angle(at: index)))
        .modifier(RemovablePhoto(index: index, side: side, onRemove: onRemove))

        if let onTap {
            Button { onTap(index) } label: { drawn.contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                .accessibilityIdentifier("photo.\(index)")
        } else {
            drawn
        }
    }

    /// Fixed per position rather than random, so the same entry always looks the same — a cluster
    /// that re-shuffles as the list scrolls past is noise, not character.
    private func angle(at index: Int) -> Double {
        guard angles.isEmpty == false else { return 0 }
        return angles[index % angles.count]
    }
}

/// A tile's long-press menu, when the cluster allows removing; inert otherwise.
private struct RemovablePhoto: ViewModifier {
    let index: Int
    let side: CGFloat
    let onRemove: ((Int) -> Void)?

    func body(content: Content) -> some View {
        if let onRemove {
            content
                .contentShape(
                    .contextMenuPreview,
                    .rect(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous)
                )
                .contextMenu {
                    Button("Remove", role: .destructive) { onRemove(index) }
                }
        } else {
            content
        }
    }
}

/// The tilts the artboards draw, named by the screen that draws them. A view asks for a cluster's
/// role; it never writes a number.
enum AtePhotoAngles {
    /// `design/v1`'s slip, composer and share clusters, repeating for a fourth and fifth photo.
    static let slip: [Double] = [-5, 4, -2, 6, -3]
    /// `Dish.dc.html`'s 150pt hero pair: `rotate(-6deg)` then `rotate(4deg)`.
    static let dishHero: [Double] = [-6, 4]
}

/// **The entry page's collage** — the mess at its largest (design rule 6).
///
/// Three tilted, overlapping squircles in the exact geometry `Entry.dc.html` draws: absolute
/// positions inside a 326-wide block, which is the page's content width plus the 4pt it bleeds into
/// the margin either side. The block is drawn at the artboard's scale and scaled as a whole to the
/// width it is given, so on a wider phone the collage grows with the page instead of stranding a gap
/// down its right-hand side.
///
/// How many photos there are changes the arrangement, never the language:
/// **0** nothing at all · **1** a single straight squircle, full width · **2** the first two slots ·
/// **3 or more** the collage as drawn, with the rest left in the entry.
struct PhotoCollage: View {
    let photos: [AtePhoto]
    /// The width of the content the collage sits in — the page's, not the block's: the collage adds
    /// its own ``bleed`` on top. Passed in rather than measured, because the page's width is
    /// arithmetic and a `GeometryReader` here would have to know its height before its width.
    var width: CGFloat = PhotoCollage.designContentWidth
    /// The colour directly behind the photos: the ring that parts two overlapping ones is drawn in it.
    var surface: Color?
    /// Opens the full-screen viewer on the photo that was tapped.
    var onTap: ((Int) -> Void)?

    @Environment(\.atePalette) private var palette

    /// One photo's place in the collage, in the artboard's own numbers.
    struct Slot: Sendable {
        var left: CGFloat
        var top: CGFloat
        var side: CGFloat
        var radius: CGFloat
        var angle: Double
    }

    /// `left/top/width/border-radius/rotate`, straight out of the markup.
    static let slots: [Slot] = [
        Slot(left: 0, top: 10, side: 200, radius: 30, angle: -4),
        Slot(left: 142, top: 0, side: 184, radius: 28, angle: 5),
        Slot(left: 96, top: 104, side: 140, radius: 24, angle: -2)
    ]

    /// The block the slots are positioned in, and the page content it was drawn against: a 390pt
    /// screen's page is 318 across, and `margin:0 -4px` makes the collage 326.
    static let designWidth: CGFloat = 326
    static let designContentWidth: CGFloat = 318
    /// `margin:0 -4px` — the collage runs 4 into the page's side padding…
    static let bleed: CGFloat = 4
    /// …and nothing more beneath it than the page's own band gap (`EntryHier` drops the old 10).
    static let spaceBelow: CGFloat = 0
    /// A lone photo is not a collage: straight, full content width, 220 tall, 24 radius.
    static let singleHeight: CGFloat = 220
    static let singleRadius: CGFloat = 24

    /// The block's height: the lowest slot in use, plus the 8 the artboard leaves under it (three
    /// photos bottom out at 244 and the block is drawn 252).
    static func height(photoCount: Int) -> CGFloat {
        let used = slots.prefix(max(0, photoCount))
        return (used.map { $0.top + $0.side }.max() ?? 0) + 8
    }

    var body: some View {
        switch photos.count {
        case 0: EmptyView()
        case 1: single
        default: collage
        }
    }

    // MARK: - Arrangements

    private var single: some View {
        tile(index: 0, size: CGSize(width: width, height: Self.singleHeight),
             radius: Self.singleRadius, angle: 0, ring: nil)
            .padding(.bottom, Self.spaceBelow)
    }

    private var collage: some View {
        let count = min(photos.count, Self.slots.count)
        let block = width + 2 * Self.bleed
        let scale = block / Self.designWidth
        // The paint order is the artboard's DOM order, which is what puts the small photo on top of
        // both big ones. A ZStack draws its first child at the back, so no zIndex is needed.
        return ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { index in
                let slot = Self.slots[index]
                tile(
                    index: index,
                    size: CGSize(width: slot.side * scale, height: slot.side * scale),
                    radius: slot.radius * scale,
                    angle: slot.angle,
                    ring: surface ?? palette.ground
                )
                .offset(x: slot.left * scale, y: slot.top * scale)
            }
        }
        // The tiles are offset, which does not size their stack: the block's own box is the artboard's.
        .frame(width: block, height: Self.height(photoCount: count) * scale, alignment: .topLeading)
        .padding(.horizontal, -Self.bleed)
        .padding(.bottom, Self.spaceBelow)
    }

    @ViewBuilder
    private func tile(index: Int, size: CGSize, radius: CGFloat, angle: Double, ring: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let content = AtePhotoContent(photo: photos[index], size: .large)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                if let ring {
                    // `box-shadow:0 0 0 3px var(--surface)` — the ring sits entirely outside the
                    // photo, so the parting between two overlapping tiles is a full 3pt.
                    shape.strokeBorder(ring, lineWidth: AteMetrics.photoRing)
                        .padding(-AteMetrics.photoRing)
                }
            }
            .rotationEffect(.degrees(angle))

        if let onTap {
            Button { onTap(index) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// A straight thumbnail — the only way a photo appears in a scrolling list (design rule 6). 16pt
/// radius, no tilt, no ring.
struct AteThumbnail: View {
    let photo: AtePhoto
    var side: CGFloat = AteMetrics.thumbnail
    /// 16, the design's thumbnail corner; the place menu's 48pt tiles draw 14.
    var radius: CGFloat = AteMetrics.receiptTop

    var body: some View {
        AtePhotoContent(photo: photo, size: .forSide(side))
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

// `DEBUG || BETA`: the gallery these feed ships to TestFlight.
#if DEBUG || BETA
extension AtePhoto {
    /// A flat coloured stand-in, so a preview shows the *composition* — tilt, overlap, ring — without
    /// a network or a bundled photo.
    @MainActor
    static func swatch(_ colour: Color) -> AtePhoto {
        let renderer = ImageRenderer(content:
            colour.frame(width: 200, height: 200).overlay(
                Image(systemName: "fork.knife")
                    .font(.system(size: 64))
                    .foregroundStyle(AteColor.ink.opacity(0.25))
            )
        )
        renderer.scale = 2
        guard let image = renderer.uiImage else { return AtePhoto() }
        return AtePhoto(image: Image(uiImage: image))
    }

    @MainActor
    static var swatches: [AtePhoto] {
        [swatch(AteColor.butter), swatch(AteColor.green), swatch(AteColor.sky)]
    }
}
#endif

#if DEBUG
#Preview("Photos") {
    VStack(alignment: .leading, spacing: AteMetrics.section) {
        PhotoCluster(photos: AtePhoto.swatches)
        PhotoCluster(photos: [AtePhoto.swatch(AteColor.coral)], side: AteMetrics.clusterPhotoComposer)
        AteThumbnail(photo: AtePhoto.swatch(AteColor.lilac))
        AteThumbnail(photo: AtePhoto())
    }
    .padding(AteMetrics.gutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ateGround()
}
#endif
