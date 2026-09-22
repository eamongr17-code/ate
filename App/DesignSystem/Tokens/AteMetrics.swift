import SwiftUI

/// **Spacing, shape and size** — the numbers in `design/v1`, named by the role they play.
///
/// Design rule 3 is the whole shape system and it is short enough to state here: **pills (999) for
/// controls, 16 for receipt tops and photos, and everything else has no container at all** — plain
/// rows parted by a hairline. There is no "card radius" token because there are no cards.
enum AteMetrics {

    // MARK: - Spacing

    /// **The screen gutter.** 20pt, everywhere.
    static let gutter: CGFloat = 20
    /// Where content starts under the status bar.
    static let contentTop: CGFloat = 60
    /// Inside a slip or a receipt.
    static let slipPadding: CGFloat = 16

    static let hairspace: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let regular: CGFloat = 12
    static let loose: CGFloat = 16
    static let section: CGFloat = 24

    /// Between slips in a list.
    static let slipGap: CGFloat = 14

    // MARK: - Shape

    /// A control. Pills only — segments, chips, fields, buttons, the tab bar.
    static let pill: CGFloat = 999
    /// A receipt's top corners, and a thumbnail in a scrolling list.
    static let receiptTop: CGFloat = 16
    /// A sheet's top corners.
    static let sheetTop: CGFloat = 32
    /// The star slider's own card — the one floating panel in the composer.
    static let panel: CGFloat = 28

    /// A photo's squircle radius: 28% of its side (80 → 22, 128 → 36), so the shape holds at any
    /// size instead of going circular when small and rectangular when large.
    static func photoRadius(side: CGFloat) -> CGFloat { (side * 0.28).rounded() }

    // MARK: - Size

    /// The minimum hit target, and the size of the square a toolbar icon sits in.
    static let hit: CGFloat = 44
    /// The floating tab bar pill.
    static let tabBarHeight: CGFloat = 66
    static let tabBarInset: CGFloat = 16
    static let tabBarBottom: CGFloat = 22
    /// The ink circle in the middle of the tab bar.
    static let composeButton: CGFloat = 54
    /// How far the ground fades up from under the tab bar (design rule 10).
    static let scrimHeight: CGFloat = 160
    /// Bottom inset for a tab screen's scrolling content. Deliberately *less* than the bar's own
    /// height (66 + 22): design rule 10 wants the last slip to run off under the scrim rather than
    /// stop dead above it, and this is how much of it stays readable.
    static let tabBarScrollInset: CGFloat = 64

    /// A chip: the small pill that carries a place, a filter, a count.
    static let chipHeight: CGFloat = 32
    /// A composer toolbar key (Score, Place).
    static let keyHeight: CGFloat = 40
    /// A segment inside a segmented pill.
    static let segmentHeight: CGFloat = 36
    /// The one ink pill per sheet.
    static let buttonHeight: CGFloat = 56
    /// A plain row with a hairline under it.
    static let rowHeight: CGFloat = 58

    /// A photo in a static, tilted cluster — journal slip.
    static let clusterPhoto: CGFloat = 80
    /// …on the entry page, where the cluster is the hero.
    static let clusterPhotoLarge: CGFloat = 84
    /// …in the composer, biggest of the three.
    static let clusterPhotoComposer: CGFloat = 90
    /// How far cluster photos overlap.
    static let clusterOverlap: CGFloat = 12
    /// The ring that separates overlapping photos, in the surface's own colour.
    static let photoRing: CGFloat = 3

    /// A straight thumbnail beside words in a scrolling list (design rule 6 — nothing in a list tilts).
    static let thumbnail: CGFloat = 84
    /// A byline avatar.
    static let avatar: CGFloat = 28

    /// One star in the slider, and its own hit target.
    static let star: CGFloat = 44
    /// The slider's track height.
    static let starTrack: CGFloat = 48

    /// A receipt's barcode band.
    static let barcodeHeight: CGFloat = 34
    /// A receipt's torn bottom edge.
    static let tornEdgeHeight: CGFloat = 8
    /// The period of one tooth in the torn edge.
    static let tornEdgePeriod: CGFloat = 12
    /// The wordmark, in a receipt's footer row.
    static let wordmarkFooter: CGFloat = 18
    /// The wordmark, on a screen's header.
    static let wordmarkHeader: CGFloat = 30

    /// A dashed rule inside a receipt.
    static let ruleWidth: CGFloat = 1.5
    static let ruleDash: [CGFloat] = [4, 3]
    /// A dot leader between a line item and its score.
    static let leaderDash: [CGFloat] = [1.5, 3.5]

    /// One device pixel — a hairline is a pixel, never a logical point. `displayScale` can be 0 in an
    /// `ImageRenderer`, hence the floor.
    static func hairline(displayScale: CGFloat) -> CGFloat {
        displayScale > 0 ? 1 / displayScale : 0.5
    }

    /// The share image. 4:5 — the tallest shape a share sheet, an iMessage bubble and an Instagram
    /// post all render without cropping.
    static let shareExport = CGSize(width: 1080, height: 1350)
    static let shareExportScale: CGFloat = 3
}
