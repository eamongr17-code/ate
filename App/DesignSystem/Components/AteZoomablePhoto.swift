import SwiftUI
import UIKit

// MARK: - One page

/// One photo that pinches, double-taps and pans like Photos — a `UIScrollView`, because SwiftUI has
/// no zooming scroll view of its own (the one control that forces UIKit here). It also owns the
/// drag-down, so it can refuse it while the photo is zoomed and win it from the pager when it is not.
struct ZoomablePhoto: UIViewRepresentable {
    let photo: AtePhoto
    @Binding var isZoomed: Bool
    var dragsToDismiss = true
    let onDrag: (CGFloat) -> Void
    let onDragEnd: (CGFloat, CGFloat) -> Void
    /// One tap, once a double tap has had its chance: the dishes' names (0083).
    var onTap: () -> Void = {}
    /// The picture's own size, each time it changes (a stand-in, then the full photo).
    var onImageSize: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.delegate = context.coordinator
        context.coordinator.scrollView = view
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onZoom = { zoomed in
            if isZoomed != zoomed { isZoomed = zoomed }
        }
        coordinator.onDrag = onDrag
        coordinator.onDragEnd = onDragEnd
        coordinator.dragsToDismiss = dragsToDismiss
        coordinator.onTap = onTap
        coordinator.onImageSize = onImageSize
        coordinator.show(photo)
    }

    static func dismantleUIView(_ view: ZoomingScrollView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: ZoomingScrollView?
        var onZoom: (Bool) -> Void = { _ in }
        var onDrag: (CGFloat) -> Void = { _ in }
        var onDragEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
        var dragsToDismiss = true
        var onTap: () -> Void = {}
        var onImageSize: (CGSize) -> Void = { _ in }
        var loading: Task<Void, Never>?
        private var shownID: AtePhoto.ID?

        /// The image goes up, and its size goes out after this update (never during one).
        private func display(_ image: UIImage?) {
            scrollView?.image = image
            guard let size = image?.size else { return }
            let report = onImageSize
            Task { @MainActor in report(size) }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            onTap()
        }

        func show(_ photo: AtePhoto) {
            guard photo.id != shownID, let scrollView else { return }
            guard let url = photo.url else {
                // A photo held in memory, with no address: the composer's staged picks, and the
                // share screen's fetched copies. Without this the viewer opened black (build 116).
                if let picture = photo.picture {
                    // The very picture the flight draws, so it lands on the page with nothing to move.
                    shownID = photo.id
                    loading?.cancel()
                    display(picture)
                    return
                }
                guard let image = photo.image else { return }
                shownID = photo.id
                loading?.cancel()
                let renderer = ImageRenderer(content: image)
                renderer.scale = 1
                display(renderer.uiImage)
                return
            }
            shownID = photo.id
            loading?.cancel()
            if let standIn = AteImagePipeline.shared.bestCached(url, size: .full) {
                display(standIn.image)
                if standIn.isFinal { return }
            }
            loading = Task { [weak self] in
                let image = await AteImagePipeline.shared.image(url, size: .full)
                guard Task.isCancelled == false, let image else { return }
                self?.display(image)
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomingScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomingScrollView)?.centreImage()
            onZoom(scrollView.zoomScale > scrollView.minimumZoomScale + 0.01)
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: scrollView.imageView)
                let scale = min(scrollView.maximumZoomScale, 2.5)
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                scrollView.zoom(
                    to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                               width: size.width, height: size.height),
                    animated: true
                )
            }
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).y
            switch recognizer.state {
            case .changed:
                onDrag(translation)
            case .ended, .cancelled, .failed:
                onDragEnd(translation, recognizer.velocity(in: recognizer.view).y)
            default:
                break
            }
        }

        /// The drag-down is only a drag-down: vertical, and only while the photo is at rest.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, pan.view === scrollView,
                  pan !== scrollView?.panGestureRecognizer else { return true }
            guard dragsToDismiss, let scrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
            let velocity = pan.velocity(in: scrollView)
            return abs(velocity.y) > abs(velocity.x) * 1.2
        }

        /// The pager waits for the drag-down to fail, so a vertical swipe dismisses rather than
        /// being swallowed by the horizontal paging.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            guard recognizer.view === scrollView, recognizer is UIPanGestureRecognizer,
                  recognizer !== scrollView?.panGestureRecognizer else { return false }
            return other.view is UIScrollView && other.view !== scrollView
        }
    }
}

/// The scroll view one photo zooms in: the image fitted to the page at rest, centred as it zooms.
final class ZoomingScrollView: UIScrollView {
    let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale <= minimumZoomScale + 0.001 else { return }
        imageView.frame = fittedFrame()
        contentSize = imageView.frame.size
        centreImage()
    }

    /// The photo's own aspect, fitted to the page — so zooming magnifies the photo, not black bars.
    private func fittedFrame() -> CGRect {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return CGRect(origin: .zero, size: bounds.size) }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }

    func centreImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}
