import SwiftUI
import UIKit

// MARK: - Opening it

/// **Open the photo viewer** — the one way anything in the app shows a photo full screen. Read it
/// from the environment and call it with the photos and the one that was tapped:
///
/// ```swift
/// @Environment(\.atePhotoViewer) private var showPhotos
/// PhotoCluster(photos: photos, onTap: { showPhotos(photos, at: $0) })
/// ```
///
/// The shell hosts it (``SwiftUICore/View/atePhotoViewerHost()``), so a slip in the journal, a card
/// in the feed, the entry page and the dish page all open the same viewer, the same way.
struct AtePhotoViewerAction: Sendable {
    fileprivate var present: (@MainActor @Sendable ([AtePhoto], Int) -> Void)?

    @MainActor
    func callAsFunction(_ photos: [AtePhoto], at index: Int) {
        present?(photos, index)
    }
}

extension EnvironmentValues {
    @Entry var atePhotoViewer = AtePhotoViewerAction()
}

extension View {
    /// Hosts the full-screen photo viewer for everything beneath this view.
    func atePhotoViewerHost() -> some View {
        modifier(AtePhotoViewerHost())
    }
}

/// What the viewer is showing: every photo of one entry (or one dish), and where it opened.
private struct AtePhotoViewing: Identifiable {
    let id = UUID()
    let photos: [AtePhoto]
    let index: Int
}

private struct AtePhotoViewerHost: ViewModifier {
    @State private var viewing: AtePhotoViewing?

    func body(content: Content) -> some View {
        let binding = $viewing
        content
            .environment(\.atePhotoViewer, AtePhotoViewerAction { photos, index in
                guard photos.isEmpty == false else { return }
                // The viewer fades itself in; the cover's own slide-up would be a sheet, not a photo.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    binding.wrappedValue = AtePhotoViewing(
                        photos: photos,
                        index: min(max(0, index), photos.count - 1)
                    )
                }
            })
            .fullScreenCover(item: $viewing) { viewing in
                AtePhotoViewer(photos: viewing.photos, index: viewing.index) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { binding.wrappedValue = nil }
                }
                // Clear, so dragging the photo down shows the page it came from underneath.
                .presentationBackground(.clear)
            }
    }
}

// MARK: - The viewer

/// **A photo, full screen.** Black, the picture whole, swipe between an entry's photos, pinch (or
/// double-tap) to zoom, and drag it down to put it back.
///
/// Deliberately the system's own shape rather than the app's — this is the one place in Ate that is
/// not paper. There is no chrome beyond the close button (design rule 1), no caption, no counter
/// beyond the page dots a multi-photo entry already earns, and no editing: the entry is where a photo
/// is managed, this is only where it is looked at.
struct AtePhotoViewer: View {
    let photos: [AtePhoto]
    /// Which one was tapped.
    @State var index: Int
    var onClose: () -> Void

    @State private var isZoomed = false
    @State private var drag: CGFloat = 0
    @State private var isShowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far a drag has to travel, or how fast, before letting go puts the photo away.
    private static let dismissDistance: CGFloat = 110
    private static let dismissVelocity: CGFloat = 900

    init(photos: [AtePhoto], index: Int, onClose: @escaping () -> Void) {
        self.photos = photos
        _index = State(initialValue: index)
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(isShowing ? backdrop : 0)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                    ZoomablePhoto(
                        photo: photo,
                        isZoomed: position == index ? $isZoomed : .constant(false),
                        onDrag: { drag = $0 },
                        onDragEnd: finishDrag
                    )
                    .tag(position)
                    .accessibilityLabel("Photo \(position + 1) of \(photos.count)")
                    .accessibilityAddTraits(.isImage)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 && isZoomed == false ? .always : .never))
            .ignoresSafeArea()
            .offset(y: drag)
            .opacity(isShowing ? 1 : 0)
        }
        .overlay(alignment: .topLeading) {
            AteIconButton(icon: .close, label: "Close", size: 24, tint: .white) { close() }
                .padding(.leading, AteMetrics.snug)
                .opacity(isShowing && drag == 0 ? 1 : 0)
        }
        .statusBarHidden()
        .accessibilityIdentifier("entry.photoViewer")
        .accessibilityAction(.escape) { close() }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isShowing = true }
        }
    }

    /// The black thins as the photo is dragged away, so the page underneath shows through.
    private var backdrop: Double {
        max(0, 1 - Double(abs(drag)) / 420)
    }

    private func finishDrag(translation: CGFloat, velocity: CGFloat) {
        if translation > Self.dismissDistance || velocity > Self.dismissVelocity {
            close(flinging: true)
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { drag = 0 }
        }
    }

    private func close(flinging: Bool = false) {
        let animation: Animation? = reduceMotion ? nil : .easeIn(duration: 0.18)
        withAnimation(animation) {
            if flinging { drag = AteScreen.height }
            isShowing = false
        } completion: {
            onClose()
        }
    }
}

// MARK: - One page

/// One photo that pinches, double-taps and pans like Photos — a `UIScrollView`, because SwiftUI has
/// no zooming scroll view of its own (the one control that forces UIKit here). It also owns the
/// drag-down, so it can refuse it while the photo is zoomed and win it from the pager when it is not.
private struct ZoomablePhoto: UIViewRepresentable {
    let photo: AtePhoto
    @Binding var isZoomed: Bool
    let onDrag: (CGFloat) -> Void
    let onDragEnd: (CGFloat, CGFloat) -> Void

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
        var loading: Task<Void, Never>?
        private var shownURL: URL?

        func show(_ photo: AtePhoto) {
            guard let url = photo.url, url != shownURL, let scrollView else { return }
            shownURL = url
            loading?.cancel()
            if let standIn = AteImagePipeline.shared.bestCached(url, size: .full) {
                scrollView.image = standIn.image
                if standIn.isFinal { return }
            }
            loading = Task { [weak scrollView] in
                let image = await AteImagePipeline.shared.image(url, size: .full)
                guard Task.isCancelled == false, let image else { return }
                scrollView?.image = image
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
            guard let scrollView, scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return false }
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

#if DEBUG
#Preview("Photo viewer") {
    AtePhotoViewer(photos: [
        AtePhoto(url: URL(string: "asset://ragu")),
        AtePhoto(url: URL(string: "asset://prawn"))
    ], index: 1, onClose: {})
}
#endif
