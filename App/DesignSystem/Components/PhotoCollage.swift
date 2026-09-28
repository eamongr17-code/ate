import AteKit
import SwiftUI

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
    @Environment(\.atePhotoOriginRelay) private var originRelay
    /// Where each tile sits, for the photo preview to grow out of (round 4).
    @State private var frames = AtePhotoTileFrames()

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

    /// A tile's corner and tilt as drawn — what the photo preview starts from.
    private func tileRadius(_ index: Int) -> CGFloat {
        guard photos.count > 1, Self.slots.indices.contains(index) else { return Self.singleRadius }
        return Self.slots[index].radius * (width + 2 * Self.bleed) / Self.designWidth
    }

    private func tileAngle(_ index: Int) -> Double {
        guard photos.count > 1, Self.slots.indices.contains(index) else { return 0 }
        return Self.slots[index].angle
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
            Button {
                originRelay?.note(frames.origin(radius: tileRadius, angle: tileAngle))
                onTap(index)
            } label: { content }
                .buttonStyle(.plain)
                .atePhotoSource(frames, index: index)
                .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                .accessibilityIdentifier("photo.\(index)")
        } else {
            content.accessibilityHidden(true)
        }
    }
}
