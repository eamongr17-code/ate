import AteKit
import SwiftUI
import UIKit

/// **The printed receipt on its coral stage** — what follows the composer's tick, and what the entry
/// page's Share shows. The photos (two at most) sit in their tilted cluster clear **above** the
/// paper, never over it; the receipt (``AteShareSlip``) lies straight under them, scaled up as a
/// whole to run 38 from each edge of the screen, so one drawing serves the screen and the sticker.
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

    var body: some View {
        VStack(spacing: AtePrintedReceiptMetrics.photoGap) {
            if photos.isEmpty == false {
                AtePhotoCluster(photos: Array(photos.prefix(2)), size: .summary, surface: AteColor.coral)
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
        enters: Bool = false
    ) {
        self.receipt = receipt
        self.photos = photos
        self.isPrinting = isPrinting
        self.breathes = breathes
        self.onAddPlace = onAddPlace
        self.onFixDish = onFixDish
        self.enters = enters
        // Its first frame is the first frame of its entrance: never drawn whole, then snatched back.
        let feeds = enters && UIAccessibility.isReduceMotionEnabled == false
        _pose = State(initialValue: feeds ? .start : .settled)
        _isFeeding = State(initialValue: feeds)
    }

    var body: some View {
        AtePrintedReceipt(
            receipt: receipt, photos: photos, isPrinting: isPrinting, breathes: breathes,
            onAddPlace: onAddPlace, onFixDish: onFixDish, pose: pose, isFeeding: isFeeding
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

enum AtePrintedReceiptMetrics {
    /// On screen the paper runs to 38 from each edge.
    static let screenInset: CGFloat = 38
    /// The cluster stands clear above the paper.
    static let photoGap: CGFloat = 18
    /// How far the feed's mask reaches past the paper's sides and top.
    static let maskReach: CGFloat = 40
}
