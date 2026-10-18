import AteKit
import SwiftUI

/// **Your photo, in its circle** (`design/rebuild/settings-photo-crop.html`, option A, approved 18 Oct)
/// — the photo just picked, whole, on black; dimmed outside the circle it will be cut to, with a
/// hairline on the circle's edge. Drag to move it, pinch to zoom; it can never leave a gap in the
/// circle (``AvatarCrop``). The glass close top left keeps the old photo; the ink tick top right
/// hands back what is in the circle, in the photo's own pixels. No words on screen.
///
/// A list's cover (`list-cover-edit.html` screen 3) is the same screen with the cover's own rounded
/// square in place of the circle — ``Frame/cover``.
struct AteAvatarCropper: View {
    enum Frame {
        case circle
        case cover
    }

    let image: UIImage
    var frame: Frame = .circle
    let onCancel: () -> Void
    let onDone: (CGRect) -> Void

    /// Where the photo sat when the current gesture began; nil until the circle has a size.
    @State private var crop: AvatarCrop?
    /// The drag and the pinch under way, measured from where they began.
    @GestureState private var moving = Moving()

    private struct Moving {
        var pan: CGSize = .zero
        var zoom: CGFloat = 1
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = proxy.size.width - 2 * AteAvatarCropperMetrics.inset
            let circle = CGRect(
                x: (proxy.size.width - diameter) / 2,
                y: (proxy.size.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            ZStack(alignment: .topLeading) {
                AteColor.viewerGround
                if let live = crop?.adjusted(pan: moving.pan, zoom: moving.zoom) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: live.drawnSize.width, height: live.drawnSize.height)
                        .offset(x: circle.minX + live.origin.x, y: circle.minY + live.origin.y)
                }
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    switch frame {
                    case .circle:
                        path.addEllipse(in: circle)
                    case .cover:
                        path.addRoundedRect(in: circle, cornerSize: CGSize(
                            width: AteListCoverMetrics.radius, height: AteListCoverMetrics.radius
                        ), style: .continuous)
                    }
                }
                .fill(AteKitColor.cropScrim, style: FillStyle(eoFill: true))
                edge
                    .frame(width: diameter, height: diameter)
                    .offset(x: circle.minX, y: circle.minY)
            }
            .contentShape(.rect)
            .gesture(gesture)
            .onAppear { if crop == nil { crop = AvatarCrop(image: image.size, diameter: diameter) } }
            .onChange(of: diameter) { _, diameter in crop = AvatarCrop(image: image.size, diameter: diameter) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            HStack {
                AteGlassDisc(icon: .close, label: "Close", identifier: "avatarCrop.close", action: onCancel)
                Spacer()
                AteGlassDisc(icon: .check, label: "Done", role: .primary, identifier: "avatarCrop.done") {
                    if let crop { onDone(crop.cropRect) }
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.snug)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("avatarCrop")
        .accessibilityAction(.escape, onCancel)
    }

    @ViewBuilder
    private var edge: some View {
        switch frame {
        case .circle:
            Circle().strokeBorder(AteKitColor.cropRing, lineWidth: AteAvatarCropperMetrics.ring)
        case .cover:
            RoundedRectangle(cornerRadius: AteListCoverMetrics.radius, style: .continuous)
                .strokeBorder(AteKitColor.cropRing, lineWidth: AteAvatarCropperMetrics.ring)
        }
    }

    /// One gesture for both, so letting go commits exactly what was drawn while it moved.
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .simultaneously(with: MagnifyGesture())
            .updating($moving) { value, state, _ in
                state = Moving(pan: value.first?.translation ?? .zero, zoom: value.second?.magnification ?? 1)
            }
            .onEnded { value in
                crop = crop?.adjusted(pan: value.first?.translation ?? .zero, zoom: value.second?.magnification ?? 1)
            }
    }
}

enum AteAvatarCropperMetrics {
    /// The circle 41 in from each side: 320 across on a 402 phone.
    static let inset: CGFloat = 41
    /// The circle's edge, a hairline.
    static let ring: CGFloat = 1
}
