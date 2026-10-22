import AteKit
import SwiftUI

/// **The dishes in a photo, named where they sit** (design/rebuild/photo-dish-tags.html, 1B; Eamon,
/// 22 Oct). A photo that shows several reviewed dishes opens clean; a tap floats each one's name
/// over it, an ink capsule with a pointer down to the dish. Only dishes the matcher placed (0083)
/// are named here; the caption under the photo names them all.
///
/// Laid over a full-screen photo fitted to the page: `imageSize` is the picture's own, so a name
/// lands on its dish whatever the photo's shape.
struct AtePhotoDishNames: View {
    struct Name: Identifiable, Hashable {
        let id: UUID
        let name: String
        let box: PhotoDishBox
    }

    let names: [Name]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let frame = Self.fitted(imageSize, in: proxy.size)
            AtePhotoDishNamesLayout {
                ForEach(names) { name in
                    let point = CGPoint(
                        x: frame.minX + frame.width * name.box.centerX,
                        y: frame.minY + frame.height * name.box.centerY
                    )
                    Text(name.name)
                        .ateText(.kitPhotoDishName)
                        .lineLimit(1)
                        .foregroundStyle(AteColor.overPhoto)
                        .padding(.horizontal, AtePhotoDishNamesMetrics.padding)
                        .frame(height: AtePhotoDishNamesMetrics.height)
                        .background(AteKitColor.photoDishName, in: .capsule)
                        .layoutValue(key: DishNamePoint.self, value: point)
                    AtePhotoDishNamePointer()
                        .fill(AteKitColor.photoDishName)
                        .frame(
                            width: AtePhotoDishNamesMetrics.pointerWidth, height: AtePhotoDishNamesMetrics.pointerHeight
                        )
                        .layoutValue(key: DishNamePoint.self, value: point)
                        .layoutValue(key: DishNameIsPointer.self, value: true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.map(\.name).joined(separator: ", "))
        .transition(.opacity)
    }

    /// Where an image of `size` lands, fitted whole and centred in `bounds` (the viewer's
    /// `.scaleAspectFit`).
    static func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        )
    }
}

enum AtePhotoDishNamesMetrics {
    static let height: CGFloat = 36
    static let padding: CGFloat = 14
    static let pointerWidth: CGFloat = 14
    static let pointerHeight: CGFloat = 7
    /// From the pointer's tip to the dish's centre.
    static let lift: CGFloat = 6
    /// A name never runs off the photo's sides: it slides, its pointer stays on the dish.
    static let edge: CGFloat = 12
}

private struct DishNamePoint: LayoutValueKey {
    static let defaultValue: CGPoint? = nil
}

private struct DishNameIsPointer: LayoutValueKey {
    static let defaultValue = false
}

/// Each name centred over its dish and kept inside the page's sides; each pointer on the dish.
private struct AtePhotoDishNamesLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = AtePhotoDishNamesMetrics.self
        for subview in subviews {
            guard let point = subview[DishNamePoint.self] else { continue }
            let size = subview.sizeThatFits(.unspecified)
            let tip = CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y - metrics.lift)
            if subview[DishNameIsPointer.self] {
                subview.place(at: tip, anchor: .bottom, proposal: ProposedViewSize(size))
            } else {
                let width = min(size.width, bounds.width - metrics.edge * 2)
                let x = min(max(tip.x - width / 2, bounds.minX + metrics.edge), bounds.maxX - metrics.edge - width)
                let y = tip.y - metrics.pointerHeight - size.height + 1
                subview.place(
                    at: CGPoint(x: x, y: max(bounds.minY + metrics.edge, y)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
            }
        }
    }
}

/// The pointer under a name: a small triangle, tip down.
struct AtePhotoDishNamePointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

#if DEBUG
#Preview("Dish names over a photo") {
    ZStack {
        AteColor.viewerGround.ignoresSafeArea()
        AtePhotoDishNames(
            names: [
                .init(id: UUID(), name: "Club Sandwich", box: PhotoDishBox([0.4, 0.55, 1, 1])!),
                .init(id: UUID(), name: "Long Black", box: PhotoDishBox([0, 0, 0.21, 0.34])!)
            ],
            imageSize: CGSize(width: 1080, height: 1350)
        )
    }
}
#endif
