import AteKit
import SwiftUI
import UIKit

/// **The printed receipt on its coral stage** — what follows the composer's tick, and what the entry
/// page's Share shows. The receipt (``AteShareSlip``) is scaled up as a whole to run 38 from each
/// edge of the screen, so one drawing serves the screen and the sticker.
///
/// With a photo (11 Oct, approved): the entry's **first** photo, whole at its own shape and never
/// cropped, with the receipt laid straight across its lower edge — the story that leaves, previewed
/// (``AteShareStory`` puts that same photo behind the same receipt). A long receipt keeps its size and
/// the photo gets smaller to leave it room (``ReceiptOnPhotoLayout``).
struct AtePrintedReceipt: View {
    let receipt: AteReceipt
    var photos: [AtePhoto] = []
    /// Still being sorted: the dish lines are skeleton bars under the paper feed.
    var isPrinting = false
    var breathes = true
    /// A receipt that cannot print without a place: its place slot is the Place key.
    var onAddPlace: (() -> Void)?
    /// Your own printed receipt: a tap on a dish name fixes it.
    var onFixDish: ((AteReceipt.Item) -> Void)?
    /// Where it is in its entrance. Settled everywhere but the moment after the tick.
    var pose: ReceiptPose = .settled
    var isFeeding = false
    /// The height the stage has to fill, when known: the photo shrinks so photo and receipt fit it.
    var room: CGFloat?

    @Environment(\.atePhotoViewer) private var showPhotos

    var body: some View {
        ReceiptOnPhotoLayout(room: room, photoWidth: AteScreen.width - 2 * AteMetrics.gutter) {
            if let photo = photos.first {
                AtePhotoContent(photo: photo, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AtePrintedReceiptMetrics.photoRadius, style: .continuous))
                    // The cover's lift, as a list's cover sits on its page.
                    .ateShadow(.cover)
                    .contentShape(Rectangle())
                    .onTapGesture { showPhotos(photos, at: 0) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Photo")
                    .scaleEffect(1 + (ReceiptEntrance.photoDrop - 1) * (1 - pose.photos))
                    .opacity(pose.photos)
            }
            paper
        }
        .environment(\.atePalette, .accent(AteColor.coral))
    }

    @ViewBuilder
    private var paper: some View {
        let slip = AteScaledLayout(scale: AtePrintedReceiptStage.scale) {
            AteShareSlip(
                receipt: receipt, isPrinting: isPrinting, breathes: breathes, onAddPlace: onAddPlace,
                onFixDish: onFixDish
            )
                .scaleEffect(AtePrintedReceiptStage.scale)
        }
        if isFeeding {
            // The paper rises out of a slot at its own foot: below the foot is inside the printer.
            slip
                .visualEffect { [fed = pose.fed] content, proxy in
                    content.offset(y: proxy.size.height * (1 - fed))
                }
                .mask(alignment: .bottom) {
                    Rectangle()
                        .padding(.horizontal, -AtePrintedReceiptMetrics.maskReach)
                        .padding(.top, -AtePrintedReceiptMetrics.maskReach)
                        .padding(.bottom, -1)
                }
        } else {
            slip
        }
    }
}

/// **The printed receipt, on screen**: when `enters`, fed out of the printer once, then its photos
/// land (``ReceiptEntrance``). With Reduce Motion it is simply there.
struct AtePrintedReceiptStage: View {
    let receipt: AteReceipt
    var photos: [AtePhoto] = []
    var isPrinting = false
    var breathes = true
    var onAddPlace: (() -> Void)?
    var onFixDish: ((AteReceipt.Item) -> Void)?
    var enters = false
    /// The height the stage has to fill (the room between the corners and the foot), when known.
    var room: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pose: ReceiptPose
    @State private var isFeeding: Bool
    @State private var hasEntered = false

    init(
        receipt: AteReceipt,
        photos: [AtePhoto] = [],
        isPrinting: Bool = false,
        breathes: Bool = true,
        onAddPlace: (() -> Void)? = nil,
        onFixDish: ((AteReceipt.Item) -> Void)? = nil,
        enters: Bool = false,
        room: CGFloat? = nil
    ) {
        self.receipt = receipt
        self.photos = photos
        self.isPrinting = isPrinting
        self.breathes = breathes
        self.onAddPlace = onAddPlace
        self.onFixDish = onFixDish
        self.enters = enters
        self.room = room
        // Its first frame is the first frame of its entrance: never drawn whole, then snatched back.
        let feeds = enters && UIAccessibility.isReduceMotionEnabled == false
        _pose = State(initialValue: feeds ? .start : .settled)
        _isFeeding = State(initialValue: feeds)
    }

    var body: some View {
        AtePrintedReceipt(
            receipt: receipt, photos: photos, isPrinting: isPrinting, breathes: breathes,
            onAddPlace: onAddPlace, onFixDish: onFixDish, pose: pose, isFeeding: isFeeding, room: room
        )
        .task { await enter() }
    }

    /// The paper runs to 38 from each edge of the screen.
    static var scale: CGFloat {
        max(1, (AteScreen.width - 2 * AtePrintedReceiptMetrics.screenInset) / AteShareSlipMetrics.width)
    }

    private func enter() async {
        guard enters, hasEntered == false else { return }
        hasEntered = true
        guard reduceMotion == false, isFeeding else {
            pose = .settled
            isFeeding = false
            return
        }
        try? await Task.sleep(for: ReceiptEntrance.groundLead)
        withAnimation(ReceiptEntrance.feedRise) { pose.fed = 1 }
        try? await Task.sleep(for: ReceiptEntrance.feedRiseTime)
        isFeeding = false
        withAnimation(ReceiptEntrance.photosLand) { pose.photos = 1 }
    }
}

/// **A photo with the receipt across its lower edge.** Two subviews: the photo (optional) and the
/// paper. The paper keeps its own size; the photo is offered the full width inside the gutters and
/// whatever height `room` leaves once the paper is placed, and fits itself to that at its own shape.
/// The paper laps the photo's foot by ``AtePrintedReceiptMetrics/photoLap`` (less on a small photo),
/// and is drawn over it.
struct ReceiptOnPhotoLayout: Layout {
    var room: CGFloat?
    /// The widest the photo runs: the screen inside the gutters.
    var photoWidth: CGFloat

    private struct Frames {
        var size: CGSize
        var photo: CGSize?
        var lap: CGFloat
        var paper: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(proposal: proposal, subviews: subviews)
        guard let paperView = subviews.last else { return }
        var top = bounds.minY
        if let photo = frames.photo, subviews.count > 1 {
            subviews[0].place(
                at: CGPoint(x: bounds.midX, y: top), anchor: .top, proposal: ProposedViewSize(photo)
            )
            top += photo.height - frames.lap
        }
        paperView.place(
            at: CGPoint(x: bounds.midX, y: top), anchor: .top, proposal: ProposedViewSize(frames.paper)
        )
    }

    private func frames(proposal: ProposedViewSize, subviews: Subviews) -> Frames {
        guard let paperView = subviews.last else { return Frames(size: .zero, lap: 0, paper: .zero) }
        let paper = paperView.sizeThatFits(.unspecified)
        guard subviews.count > 1 else { return Frames(size: paper, lap: 0, paper: paper) }
        let width = min(proposal.width ?? photoWidth, photoWidth)
        let lapMax = AtePrintedReceiptMetrics.photoLap
        let height = max(
            AtePrintedReceiptMetrics.photoMinHeight,
            (room ?? AtePrintedReceiptMetrics.photoDefaultRoom) - paper.height + lapMax
        )
        let photo = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: height))
        let lap = min(lapMax, photo.height * AtePrintedReceiptMetrics.photoLapShare)
        let size = CGSize(width: max(photo.width, paper.width), height: photo.height - lap + paper.height)
        return Frames(size: size, photo: photo, lap: lap, paper: paper)
    }
}

/// A view drawn at `scale` **and laid out at that size** — `scaleEffect` alone draws larger but keeps
/// the old room.
struct AteScaledLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let inner = child.sizeThatFits(ProposedViewSize(
            width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale }
        ))
        return CGSize(width: inner.width * scale, height: inner.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let inner = ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: inner)
    }
}

extension AteReceipt {
    /// The share screen's title (Eamon, 10 Oct): "Share your dish", or "dishes" for more than one.
    var shareTitle: String {
        items.count > 1 ? "Share your dishes" : "Share your dish"
    }
}

enum AtePrintedReceiptMetrics {
    /// On screen the paper runs to 38 from each edge.
    static let screenInset: CGFloat = 38
    /// The photo's corners: the paper's own top, at the stage's scale (16, design rule 3).
    @MainActor static var photoRadius: CGFloat { AteShareSlipMetrics.radius * AtePrintedReceiptStage.scale }
    /// How far the receipt laps the foot of the photo, at most…
    static let photoLap: CGFloat = 96
    /// …and never more than this share of a small photo.
    static let photoLapShare: CGFloat = 0.3
    /// The smallest a photo gets beside a long receipt (the stage scrolls past that).
    static let photoMinHeight: CGFloat = 160
    /// The room assumed where the caller does not say (the kit gallery).
    static let photoDefaultRoom: CGFloat = 560
    /// How far the feed's mask reaches past the paper's sides and top.
    static let maskReach: CGFloat = 40
}
