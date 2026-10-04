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

    /// …with the tile a list chose for it (``DishLetter/neighbourly(_:)``).
    static func dish(_ letter: DishLetter, cover: String?) -> AtePhoto {
        AtePhoto(id: letter.dishID, url: cover.flatMap(URL.init(string:)), dish: letter)
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
    /// Set by a list, where the dish's own accent would repeat the tile beside it
    /// (``neighbourly(_:)``). `nil` is the dish's own.
    var paletteIndex: Int?

    /// Coral, green, pink, sky, lilac — the accents less butter.
    static let accents: [Color] = [AteColor.coral, AteColor.green, AteColor.pink, AteColor.sky, AteColor.lilac]

    var accent: Color {
        Self.accents[paletteIndex ?? DishTileIdentity.paletteIndex(for: dishID, count: Self.accents.count)]
    }
    var letter: String { DishTileIdentity.initial(for: name) }

    /// **The letter tiles of a list, in the order it draws them** (round 4): neighbours never share
    /// an accent, and the same list always paints the same way
    /// (``DishTileIdentity/paletteIndices(for:count:)``). Every list of dish thumbnails builds its
    /// tiles through this — Saved, a place's menu, the dish rows in Search, Ratings.
    static func neighbourly(_ dishes: [(dishID: UUID, name: String)]) -> [DishLetter] {
        let indices = DishTileIdentity.paletteIndices(for: dishes.map(\.dishID), count: accents.count)
        return zip(dishes, indices).map { DishLetter(dishID: $0.dishID, name: $0.name, paletteIndex: $1) }
    }
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
    /// The photo will not load and has no letter tile to fall back on (``AtePhotoContent``).
    var onFailure: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous)
        return AtePhotoContent(photo: photo, size: .forSide(side), onFailure: onFailure)
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
    /// A photo that will not load, with no dish letter to stand in for it: the caller decides what
    /// goes there instead (a cluster drops the tile).
    var onFailure: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        if let image = photo.image {
            image.resizable().aspectRatio(contentMode: contentMode)
        } else if let url = photo.url {
            AteRemotePhoto(
                url: url, size: size, contentMode: contentMode, failure: photo.dish,
                onFailure: photo.dish == nil ? onFailure : nil
            )
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
    @Environment(\.atePhotoOriginRelay) private var originRelay
    /// Where each tile sits, for the photo preview to grow out of (round 4).
    @State private var frames = AtePhotoTileFrames()
    /// Photos that would not load (build 88): dropped from the strip, never left as an empty tile.
    @State private var failed: Set<AtePhoto.ID> = []

    /// What the strip draws: every photo but the ones that failed, each with its place in `photos`
    /// (a tap and a removal still name the photo the caller handed in).
    private var shown: [(index: Int, photo: AtePhoto)] {
        photos.enumerated().filter { failed.contains($0.element.id) == false }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        let shown = shown
        if shown.isEmpty == false || photos.isEmpty {
            strip(shown)
        }
    }

    @ViewBuilder
    private func strip(_ shown: [(index: Int, photo: AtePhoto)]) -> some View {
        let cluster = HStack(spacing: -overlap) {
            ForEach(Array(shown.enumerated()), id: \.element.photo.id) { position, item in
                tile(item.photo, at: item.index, position: position, count: shown.count)
                    .zIndex(Double(shown.count - position))
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
                .accessibilityLabel(shown.count == 1 ? "1 photo" : "\(shown.count) photos")
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

    /// `index` is the photo's place in `photos`; `position` its place on the strip, which the tilt
    /// follows so a dropped photo never leaves the strip looking gapped.
    @ViewBuilder
    private func tile(_ photo: AtePhoto, at index: Int, position: Int, count: Int) -> some View {
        let drawn = AtePhotoTile(
            photo: photo,
            side: side,
            ring: count > 1 ? (surface ?? palette.ground) : nil,
            onFailure: { failed.insert(photo.id) }
        )
        .rotationEffect(.degrees(angle(at: position)))
        .modifier(RemovablePhoto(index: index, side: side, onRemove: onRemove))

        if let onTap {
            Button {
                originRelay?.note(frames.origin(
                    radius: { _ in AteMetrics.photoRadius(side: side) },
                    angle: { tapped in angle(at: shown.firstIndex { $0.index == tapped } ?? tapped) }
                ))
                onTap(index)
            } label: { drawn.contentShape(.rect) }
                .buttonStyle(.plain)
                .atePhotoSource(frames, index: index)
                .accessibilityLabel("Photo \(position + 1) of \(count)")
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

/// A tile's X and its long-press menu, when the cluster allows removing; inert otherwise. The X is
/// the visible way (round 4); the long press stays as the second.
private struct RemovablePhoto: ViewModifier {
    let index: Int
    let side: CGFloat
    let onRemove: ((Int) -> Void)?

    @Environment(\.atePalette) private var palette

    func body(content: Content) -> some View {
        if let onRemove {
            content
                .overlay(alignment: .topTrailing) {
                    Button { onRemove(index) } label: {
                        AteIcon.close.view(size: Self.glyph)
                            .foregroundStyle(palette.inverted)
                            .frame(width: Self.disc, height: Self.disc)
                            .background(palette.fg, in: .circle)
                            // Parted from the photo under it by a ring in the surface colour, as the
                            // photos are from each other.
                            .overlay { Circle().strokeBorder(palette.ground, lineWidth: 2).padding(-2) }
                            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .offset(x: Self.shift, y: -Self.shift)
                    .accessibilityLabel("Remove photo \(index + 1)")
                    .accessibilityIdentifier("photo.remove.\(index)")
                }
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

    /// A small disc over the tile's corner — 22 across, its X 11, sitting 4 in from the corner.
    private static let disc: CGFloat = 22
    private static let glyph: CGFloat = 11
    private static let inset: CGFloat = 4
    /// The 44 target is centred on the disc, so it moves out by the difference.
    private static let shift = AteMetrics.hit / 2 - disc / 2 - inset
}

/// The tilts the artboards draw, named by the screen that draws them. A view asks for a cluster's
/// role; it never writes a number.
enum AtePhotoAngles {
    /// `design/v1`'s slip, composer and share clusters, repeating for a fourth and fifth photo.
    static let slip: [Double] = [-5, 4, -2, 6, -3]
    /// `Dish.dc.html`'s 150pt hero pair: `rotate(-6deg)` then `rotate(4deg)`.
    static let dishHero: [Double] = [-6, 4]
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
                AteIcon.dish.view(size: 64)
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
