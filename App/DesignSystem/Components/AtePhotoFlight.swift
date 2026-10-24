import AteKit
import QuartzCore
import SwiftUI
import UIKit

/// **The photo on its way between its tile and the screen** (24 Oct, rebuild): one plain picture in
/// one rounded frame, drawn for one number, `progress` — 0 on the tile, 1 at rest on the page. The
/// view is ``Animatable`` on that number alone, so every frame of the open and the close is
/// ``PhotoFlight/between(_:_:progress:)`` (tested in AteKit), and the first and last frames are the
/// tile and the page exactly. Nothing else moves the photo, and nothing corrects it once it lands.
struct AtePhotoFlightImage: View, Animatable {
    let path: AtePhotoFlightPath
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let frame = PhotoFlight.between(path.home, path.away, progress: progress)
        // What sits on the page over the tile (its ring, the photos lapping it) is on it as it
        // leaves and as it lands, and gone a third of the way out.
        let onTile = max(0, 1 - Double(progress) * 3)
        GeometryReader { proxy in
            let window = proxy.frame(in: .global).origin
            ZStack {
                AtePhotoFramed(image: path.image, frame: frame, ring: path.ring, ringOpacity: onTile, window: window)
                // The photos that lap over its tile in the cluster, drawn over it again, so it
                // leaves from under them and lands back under them (24 Oct: it flew over them and
                // they jumped back on top as it landed).
                ForEach(path.covers.indices, id: \.self) { position in
                    let cover = path.covers[position]
                    AtePhotoFramed(
                        image: cover.image, frame: cover.frame, ring: cover.ring, ringOpacity: 1, window: window
                    )
                    .opacity(onTile)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A picture in its frame, as ``PhotoFlight/Frame`` says: cropped, rounded, tilted, placed.
private struct AtePhotoFramed: View {
    let image: UIImage
    let frame: PhotoFlight.Frame
    let ring: Color?
    let ringOpacity: Double
    let window: CGPoint

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: frame.picture.width, height: frame.picture.height)
            .offset(x: frame.picture.minX, y: frame.picture.minY)
            .frame(width: frame.size.width, height: frame.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: frame.radius, style: .continuous))
            .background {
                if let ring {
                    RoundedRectangle(cornerRadius: frame.radius + AteMetrics.photoRing, style: .continuous)
                        .fill(ring)
                        .padding(-AteMetrics.photoRing)
                        .opacity(ringOpacity)
                }
            }
            .rotationEffect(.degrees(frame.angle))
            .position(x: frame.center.x - window.x, y: frame.center.y - window.y)
    }
}

/// One photo's way between its tile and the page, fixed before it sets off: the flight never
/// retargets on the way.
struct AtePhotoFlightPath {
    let image: UIImage
    let home: PhotoFlight.Frame
    let away: PhotoFlight.Frame
    /// The tile's ring colour, when it has one.
    var ring: Color?
    /// The cluster's photos that lap over the tile, bottom first, each where it sits on the page.
    var covers: [Cover] = []

    struct Cover {
        let image: UIImage
        let frame: PhotoFlight.Frame
        let ring: Color?
    }
}

/// The pager follows a drag down, shrinking a little as Photos does.
struct AtePhotoDragged: ViewModifier {
    let drag: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(PhotoFlight.scale(drag: drag))
            .offset(y: drag)
    }
}

enum AtePhotoViewerMetrics {
    /// The open and the close. A curve of fixed length, not a spring: a spring's long, invisible tail
    /// either holds the viewer up (build 197) or gets cut short a few points from home (build 198,
    /// the jolt). This one is at its end, exactly, when it says it is done. Fast out, soft landing.
    static let fly: Animation = .timingCurve(0.25, 0.8, 0.25, 1, duration: 0.34)
    /// A photo with no tile to fly to (zoomed in, or opened from somewhere that is not a tile).
    static let fade: Animation = .easeOut(duration: 0.2)
}

// MARK: - Frames

/// Runs once the screen has refreshed: everything done before it is on the glass.
@MainActor
enum AteNextFrame {
    static func run(_ action: @escaping @MainActor () -> Void) {
        let ticker = Ticker(action: action)
        // The link holds its target until it is invalidated, on its one tick.
        CADisplayLink(target: ticker, selector: #selector(Ticker.tick(_:))).add(to: .main, forMode: .common)
    }

    @MainActor
    private final class Ticker: NSObject {
        let action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func tick(_ link: CADisplayLink) {
            link.invalidate()
            action()
        }
    }
}

/// Tells once the view it sits in is in a window. A cover's content lays out (and fires `onAppear`)
/// before it is on the screen. The first time a launch presents it, that gap can outlast the whole
/// flight, which is the likeliest reason the first open of a launch never animated.
struct AteOnWindow: UIViewRepresentable {
    let action: @MainActor () -> Void

    func makeUIView(context: Context) -> Sensor { Sensor(action: action) }
    func updateUIView(_ view: Sensor, context: Context) {}

    final class Sensor: UIView {
        private var action: (@MainActor () -> Void)?

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let action else { return }
            self.action = nil
            action()
        }
    }
}
