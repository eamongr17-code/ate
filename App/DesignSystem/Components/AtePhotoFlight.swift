import AteKit
import SwiftUI
import UIKit

/// The photo on its way between its tile and the screen (24 Oct, round 4): one plain picture, filled
/// into a rounded frame that moves from the tile to the page or back (``PhotoFlight``). The frame is
/// the crop, so the picture is the tile's square at home and the whole photo at rest, and nothing
/// in between depends on the UIKit pager taking a mask (builds 194–196: it never did).
struct AtePhotoFlightImage: View {
    let image: UIImage
    let frame: PhotoFlight.Frame

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.frame(in: .global).origin
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: frame.size.width, height: frame.size.height)
                .clipShape(RoundedRectangle(cornerRadius: frame.radius, style: .continuous))
                .rotationEffect(.degrees(frame.angle))
                .position(x: frame.center.x - window.x, y: frame.center.y - window.y)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One photo's way between its tile and the page.
struct AtePhotoFlightPath {
    let image: UIImage
    let home: PhotoFlight.Frame
    let away: PhotoFlight.Frame
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
    /// The photo's flight out of its tile and back.
    /// No bounce: an overshoot of a small tile spills over the text round it. The caption and close
    /// button fade with it, and the viewer comes down as it lands, not after the spring's tail
    /// (build 197 waited ~0.5s for both).
    static let fly: Animation = .smooth(duration: 0.35)
}
