import SwiftUI

/// A photo, or the space held for one. `image == nil` is a photo that hasn't loaded yet — never an
/// error state and never a spinner (design: skeletons of the real component, not spinners).
struct AtePhoto: Identifiable, Equatable {
    let id: UUID
    var image: Image?
    /// A photo that lives on the server. Loaded by the tile itself, so a caller never has to hold an
    /// image cache — and a photo still arriving holds its space rather than collapsing the cluster.
    var url: URL?

    init(id: UUID = UUID(), image: Image? = nil, url: URL? = nil) {
        self.id = id
        self.image = image
        self.url = url
    }
}

/// A squircle photo: radius is 28% of the side, so the shape reads the same at 80pt and at 128pt.
struct AtePhotoTile: View {
    let photo: AtePhoto
    let side: CGFloat
    /// The ring that separates overlapping photos, drawn in the colour of the surface behind them.
    var ring: Color?

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteMetrics.photoRadius(side: side), style: .continuous)
        return AtePhotoContent(photo: photo)
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

/// What actually fills a tile: a picked image, a photo still coming down the wire, or the space it
/// will take. Never a spinner — the design asks for skeletons of the real component.
private struct AtePhotoContent: View {
    let photo: AtePhoto

    @Environment(\.atePalette) private var palette

    var body: some View {
        if let image = photo.image {
            image.resizable().scaledToFill()
        } else if let url = photo.url {
            #if DEBUG
            if let bundled = Self.bundled(url) {
                bundled.resizable().scaledToFill()
            } else {
                remote(url)
            }
            #else
            remote(url)
            #endif
        } else {
            palette.field
        }
    }

    private func remote(_ url: URL) -> some View {
        AsyncImage(url: url) { loaded in
            loaded.resizable().scaledToFill()
        } placeholder: {
            palette.field
        }
    }

    #if DEBUG
    /// The prototype photos, for `-ate-preview-data`. `asset://ragu` is the design's own fixture;
    /// `preview://<entry>/<n>` is what the in-memory service mints when a written entry's photos
    /// "upload", so a drive sees food rather than grey squares.
    private static func bundled(_ url: URL) -> Image? {
        switch url.scheme {
        case "asset":
            return url.host().map { Image("Photos/\($0)") }
        case "preview":
            let index = Int(url.lastPathComponent) ?? 0
            return Image("Photos/\(names[abs(index) % names.count])")
        default:
            return nil
        }
    }

    private static let names = ["ragu", "prawn", "tiramisu", "sushi", "burger", "pizza", "cake", "penne"]
    #endif
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

    @Environment(\.atePalette) private var palette

    /// The prototype's angles, repeating for a fourth and fifth photo.
    private static let angles: [Double] = [-5, 4, -2, 6, -3]

    var body: some View {
        HStack(spacing: -AteMetrics.clusterOverlap) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                AtePhotoTile(
                    photo: photo,
                    side: side,
                    ring: photos.count > 1 ? (surface ?? palette.ground) : nil
                )
                    .rotationEffect(.degrees(Self.angles[index % Self.angles.count]))
                    .zIndex(Double(photos.count - index))
            }
        }
        // The artboards' own `padding:4px 0 2px 6px` around a cluster.
        .padding(.top, AteMetrics.tight)
        .padding(.bottom, AteMetrics.hairspace)
        .padding(.leading, 6)
        .accessibilityElement()
        .accessibilityLabel(photos.count == 1 ? "1 photo" : "\(photos.count) photos")
    }
}

/// A straight thumbnail — the only way a photo appears in a scrolling list (design rule 6). 16pt
/// radius, no tilt, no ring.
struct AteThumbnail: View {
    let photo: AtePhoto
    var side: CGFloat = AteMetrics.thumbnail

    @Environment(\.atePalette) private var palette

    var body: some View {
        AtePhotoContent(photo: photo)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: AteMetrics.receiptTop, style: .continuous))
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
