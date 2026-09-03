import AteKit
import SwiftUI

/// What a tile needs to know about a dish: who it is, what it's called, and whether it has a face.
///
/// The `id` is the **canonical** dish id, never the display name: two restaurants' "Pad Thai" are
/// two dishes and must not be the same tile, and a dish renamed tomorrow must not change colour.
struct DishTileSubject: Hashable {
    let id: UUID
    let name: String
    let photoURL: URL?

    init(id: UUID, name: String, photoURL: URL? = nil) {
        self.id = id
        self.name = name
        self.photoURL = photoURL
    }
}

/// **A dish is never a blank** (design-language §3).
///
/// One component for every place a dish needs a visual anchor in a gutter: a diary row's 44pt
/// square, a restaurant menu's 56pt, a search result, a sibling row. It shows the photo when there
/// is one and a tile generated from the dish's own identity when there isn't — never a grey box,
/// which is what an imageless menu looked like before and which reads as fifteen failed loads.
///
/// Gutter tiles are **structure**, so they are always filled. The full-width wells on a feed row and
/// an entry card are **decoration**: with no photo that zone is simply absent, and those surfaces
/// don't use this view.
struct DishTile: View {
    let dish: DishTileSubject
    var size: CGFloat = Theme.Size.thumbnail

    var body: some View {
        Group {
            if let url = dish.photoURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    DishTileArtwork(dish: dish, well: size)
                }
            } else {
                DishTileArtwork(dish: dish, well: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        .accessibilityHidden(true)
    }
}

/// The generated half of a tile — the part with no photo behind it.
///
/// Split out so the receipt's media band can render the same artwork at poster scale: an imageless
/// receipt is a typographic poster, not a receipt with a hole in it.
struct DishTileArtwork: View {
    let dish: DishTileSubject
    /// The square (or, on the receipt, the short side) this artwork fills. Type scales from it.
    let well: CGFloat

    /// §9's question #1, read live so flipping the toggle re-lays out a 40-row diary immediately.
    @AppStorage(DesignDebugSettings.dishTileStyleKey)
    private var styleRaw = DishTileStyle.designDefault.rawValue

    private var style: DishTileStyle {
        #if DEBUG || BETA
        DishTileStyle(rawValue: styleRaw) ?? .designDefault
        #else
        .designDefault
        #endif
    }

    var body: some View {
        switch style {
        case .typographic: typographic
        case .monogram: monogram
        }
    }

    /// **Variant A.** The dish's own name, over-scaled and deliberately running out of the square —
    /// legible at 56pt, a word at 44pt, two letters below 32pt (the degradation is `AteKit`'s and is
    /// tested there). The clipping is the point: the tile is texture that happens to be readable.
    private var typographic: some View {
        // The FILL sizes the tile and the text is an overlay pinned to its top-left corner. Written
        // this way round for two reasons: the artwork then fills whatever frame it is handed (a
        // 44pt square in a diary row, a 4:5 band on the receipt), and an overlay larger than its
        // parent overflows and is cut, where a `background` behind an over-sized child would grow
        // to fit it.
        Theme.Color.surfaceTile
            .overlay(alignment: .topLeading) {
                Text(DishTileIdentity.typographicText(for: dish.name, well: well))
                    .font(Theme.Text.tileTypographic(well: well))
                    .foregroundStyle(Theme.Color.tileForeground)
                    .lineLimit(2)
                    // `fixedSize` is what makes this a *tile* and not a truncated label: the text
                    // lays out at its intrinsic width and the well cuts it. Without it SwiftUI
                    // ellipsises instead ("T…"), which reads as a bug rather than as a crop.
                    .fixedSize()
                    .padding(.horizontal, Theme.Spacing.tight)
                    .padding(.top, Theme.Spacing.tight)
            }
            .clipped()
    }

    /// **Variant B.** Two letters, centred, on a step of the palette chosen deterministically from
    /// the dish's UUID — so a menu reads as tonal texture and the same dish is the same tone
    /// everywhere it appears, forever.
    private var monogram: some View {
        paletteStep
            .overlay {
                Text(DishTileIdentity.monogram(for: dish.name))
                    .font(Theme.Text.tileMonogram(well: well))
                    .foregroundStyle(Theme.Color.tileForeground)
                    .fixedSize()
            }
            .clipped()
    }

    private var paletteStep: Color {
        let palette = Theme.Color.tilePalette
        guard !palette.isEmpty else { return Theme.Color.surfaceTile }
        return palette[DishTileIdentity.paletteIndex(for: dish.id, count: palette.count)]
    }
}

#Preview("Dish tiles") {
    let names = [
        "Prawn betel leaf", "Cacio e Pepe", "Kouign-Amann", "Son-in-law eggs",
        "Tonkotsu", "Steak and chips", "Pho", "Salt and pepper squid"
    ]
    return ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            ForEach([Theme.Size.tileSmall, Theme.Size.thumbnail, 96], id: \.self) { size in
                Text("\(Int(size))pt").font(Theme.Text.caption)
                HStack(spacing: Theme.Spacing.snug) {
                    ForEach(names, id: \.self) { name in
                        DishTile(dish: DishTileSubject(id: UUID(), name: name), size: size)
                    }
                }
            }
        }
        .padding(Theme.Spacing.gutter)
    }
}
