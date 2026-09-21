import SwiftUI

/// A photo, or the space held for one. `image == nil` is a photo that hasn't loaded yet — never an
/// error state and never a spinner (design: skeletons of the real component, not spinners).
struct AtePhoto: Identifiable, Equatable {
    let id: UUID
    var image: Image?

    init(id: UUID = UUID(), image: Image? = nil) {
        self.id = id
        self.image = image
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
        return Group {
            if let image = photo.image {
                image.resizable().scaledToFill()
            } else {
                palette.field
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay {
            if let ring {
                shape.strokeBorder(ring, lineWidth: AteMetrics.photoRing)
                    .padding(-AteMetrics.photoRing / 2)
            }
        }
        .accessibilityHidden(true)
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

    @Environment(\.atePalette) private var palette

    /// The prototype's angles, repeating for a fourth and fifth photo.
    private static let angles: [Double] = [-5, 4, -2, 6, -3]

    var body: some View {
        HStack(spacing: -AteMetrics.clusterOverlap) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                AtePhotoTile(photo: photo, side: side, ring: photos.count > 1 ? palette.ground : nil)
                    .rotationEffect(.degrees(Self.angles[index % Self.angles.count]))
                    .zIndex(Double(photos.count - index))
            }
        }
        .padding(.vertical, AteMetrics.tight)
        .padding(.leading, AteMetrics.snug)
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
        Group {
            if let image = photo.image {
                image.resizable().scaledToFill()
            } else {
                palette.field
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: AteMetrics.receiptTop, style: .continuous))
        .accessibilityHidden(true)
    }
}

#if DEBUG
extension AtePhoto {
    /// A flat coloured stand-in, so a preview shows the *composition* — tilt, overlap, ring — without
    /// a network or a bundled photo.
    @MainActor
    static func swatch(_ colour: Color, seed: Int = 0) -> AtePhoto {
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
