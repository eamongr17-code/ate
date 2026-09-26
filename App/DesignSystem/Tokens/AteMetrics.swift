import SwiftUI
import UIKit

/// **The page the design was drawn on.**
///
/// `design/v1` lays every screen out on a full-bleed 390×844 page: the first row sits 60 from the
/// *top of the screen* and the floating tab bar 22 from the bottom — both measured past the status
/// bar and past the home indicator, which the artboards simply draw over. A screen that adds the
/// design's 60 on top of the window's own 62pt inset starts 122 down the page, which is the single
/// biggest way a faithful layout stops looking like its artboard.
///
/// So the app carries the window's insets itself and spends the design's numbers against them. It is
/// read from UIKit rather than a `GeometryReader` because a `NavigationStack` re-establishes the
/// safe area for everything inside it, which makes the geometry a view sees a lie about the page.
@MainActor
enum AteScreen {
    /// The window's own size. The artboards are 390×844; anything that has to run off the bottom of
    /// the screen (the entry page) needs the real number rather than the drawn one.
    static var size: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 390, height: 844)
    }

    static var width: CGFloat { size.width }
    static var height: CGFloat { size.height }

    static var safeArea: UIEdgeInsets {
        if let cached { return cached }
        let insets = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
        if insets != .zero { cached = insets }
        return insets
    }

    private static var cached: UIEdgeInsets?

    /// A sheet's height, given as the artboard gives it — out of the 844-tall page it was drawn on.
    static func sheetHeight(_ artboard: CGFloat) -> CGFloat {
        (height * artboard / 844).rounded()
    }
}

extension View {
    /// Starts a screen's content where the artboard starts it — 60 from the top of the screen, or
    /// whatever that screen's own markup says (`Feed` and `Search` use 62, `You` 70).
    func ateContentTop(_ top: CGFloat = AteMetrics.contentTop) -> some View {
        modifier(AteContentTop(top: top))
    }
}

private struct AteContentTop: ViewModifier {
    let top: CGFloat

    func body(content: Content) -> some View {
        content.padding(.top, top - AteScreen.safeArea.top)
    }
}

extension View {
    /// The bottom half of the same rule: a control the markup pins `bottom:40px` from the bottom of
    /// the *page* (Welcome's pill, Handle's Continue) sits 40 from the bottom of the screen, not 40
    /// above the home indicator.
    func ateContentBottom(_ bottom: CGFloat) -> some View {
        padding(.bottom, max(0, bottom - AteScreen.safeArea.bottom))
    }
}

/// **Spacing, shape and size** — the numbers in `design/v1`, named by the role they play.
///
/// Design rule 3 is the whole shape system and it is short enough to state here: **pills (999) for
/// controls, 16 for receipt tops and photos, and everything else has no container at all** — plain
/// rows parted by a hairline. There is no "card radius" token because there are no cards.
enum AteMetrics {

    // MARK: - Spacing

    /// **The screen gutter.** 20pt, everywhere a screen is not a list of slips.
    static let gutter: CGFloat = 20
    /// **The list gutter** — 12pt either side of the slips in the journal, the feed and a profile,
    /// and of the headers above them (`padding:… 12px`), so a slip is as wide as the phone allows.
    static let listGutter: CGFloat = 12
    /// Where content starts under the status bar.
    static let contentTop: CGFloat = 60
    /// Inside a slip or a receipt, either side.
    static let slipPadding: CGFloat = 16
    /// …above its contents when it opens on a byline (`padding:12px 16px 14px`)…
    static let slipPaddingTop: CGFloat = 12
    /// …and when it opens straight on the dish stack, whose 44pt rows carry their own air
    /// (`padding:4px 16px 14px`).
    static let slipPaddingTopBare: CGFloat = 4
    static let slipPaddingBottom: CGFloat = 14
    /// Between a slip's bands: the byline, the dish stack, the words, the photos, the foot line
    /// (`gap:10px`).
    static let slipBandGap: CGFloat = 10
    /// A slip's foot line — pin, place, suburb, and the date or age on the right
    /// (`.placeline`: `min-height:28px; margin:2px 0 -6px`).
    static let slipFootHeight: CGFloat = 28
    static let slipFootTop: CGFloat = 2
    static let slipFootBottom: CGFloat = -6
    /// A dish row's own air above and below a name that wraps (`padding:9px 0`).
    static let slipDishPadding: CGFloat = 9
    /// A slip's corners when it has no torn edge — the statement slip (`.slip.whole`).
    static let slipCorner: CGFloat = 16

    static let hairspace: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 8
    static let regular: CGFloat = 12
    static let loose: CGFloat = 16
    static let section: CGFloat = 24

    /// Between slips in a list.
    static let slipGap: CGFloat = 14

    // `FeedTight.dc.html` (2026-09-26) — the feed alone, a notch closer: header bottom 14 → 10,
    // slip gap 14 → 10, slip padding 12/16/14 → 10/14/12, band gap 10 → 8.
    static let feedHeaderBottom: CGFloat = 10
    static let feedSlipGap: CGFloat = 10
    static let slipTightPaddingTop: CGFloat = 10
    static let slipTightPadding: CGFloat = 14
    static let slipTightPaddingBottom: CGFloat = 12
    static let slipTightBandGap: CGFloat = 8

    /// A place's list of visits: yours first, then everyone's, `gap:12px`, on the 20 gutter
    /// (`RestaurantVisits`).
    static let placeSlipGap: CGFloat = 12

    // MARK: - The page
    //
    // `EntryHier.dc.html`'s own numbers. The entry is ONE white page on the linen ground — not a card and
    // not a receipt — so it has its own small set: where it starts, how far it is inset, and the
    // rhythm inside it.

    /// The page's side margins (`.slipwrap` `margin:8px 16px 0`).
    static let pageInset: CGFloat = 16
    /// …and its clearance under the top bar.
    static let pageGap: CGFloat = 8
    /// Its top corners. The only 24 in the app, and the reason it reads as paper laid on the ground
    /// rather than a receipt (16) or a sheet (32).
    static let pageTop: CGFloat = 24
    /// Inside the page: `padding:8px 20px 0` (`EntryHier`) — it opens straight on a 44pt dish row,
    /// which carries its own air.
    static let pagePaddingTop: CGFloat = 8
    static let pagePaddingSide: CGFloat = 20
    /// Between the page's bands (`gap:16px`).
    static let pageBandGap: CGFloat = 16
    /// How far the page runs off the bottom of the screen: the artboard's `min-height:760` starts at
    /// 112 on an 844-tall page, so 28 of it is always past the fold (design rule 10).
    static let pageOvershoot: CGFloat = 28

    // MARK: - Shape

    /// A control. Pills only — segments, chips, fields, buttons, the tab bar.
    static let pill: CGFloat = 999
    /// A receipt's top corners, and a thumbnail in a scrolling list.
    static let receiptTop: CGFloat = 16
    /// A sheet's top corners.
    static let sheetTop: CGFloat = 32
    /// The star slider's own card — the one floating panel in the composer.
    static let panel: CGFloat = 28

    /// A photo's squircle radius: 28% of its side, rounded down the way the artboards write it
    /// (80 → 22, 84 → 23, 90 → 25, 150 → 42), so the shape holds at any size instead of going
    /// circular when small and rectangular when large.
    static func photoRadius(side: CGFloat) -> CGFloat { (side * 0.28).rounded(.down) }

    // MARK: - Size

    /// The minimum hit target, and the size of the square a toolbar icon sits in.
    static let hit: CGFloat = 44
    /// Bottom inset for a tab screen's scrolling content, so the last slip clears the glass bar
    /// (design rule 10: it runs off under the bar rather than stopping dead above it).
    static let tabBarScrollInset: CGFloat = 64
    /// A tab icon in the system bar — the artboard's 22 plus the 2 the bar's item box leaves
    /// around a symbol.
    static let tabIcon: CGFloat = 24

    /// Between a sheet's bands.
    static let sheetGap: CGFloat = 14
    /// A sheet's clearance above the home indicator, under its one ink pill.
    static let sheetBottom: CGFloat = 34

    /// A chip: the small pill that carries a place, a filter, a count.
    static let chipHeight: CGFloat = 32
    /// A pill text field — a sheet's search, `AddPlace`'s three.
    static let fieldHeight: CGFloat = 50
    /// A composer toolbar key (Score, Place).
    static let keyHeight: CGFloat = 40
    /// A segment inside a segmented pill.
    static let segmentHeight: CGFloat = 36
    /// The one ink pill per sheet.
    static let buttonHeight: CGFloat = 56
    /// A plain row with a hairline under it.
    static let rowHeight: CGFloat = 58
    /// …and the settings variant: 56 with a 10pt gap (`Settings.dc.html`), a shade tighter than a
    /// search result because a settings row is one line and never carries a subtitle.
    static let settingsRowHeight: CGFloat = 56
    static let settingsRowGap: CGFloat = 10
    /// The chevron at the end of a settings row. Smaller than a toolbar icon on purpose — it is
    /// punctuation, not a control.
    static let settingsChevron: CGFloat = 15
    /// The check beside the chosen Appearance — `Handle`'s check, at its own 18.
    static let settingsCheck: CGFloat = 18

    /// A photo in a static, tilted cluster — journal slip.
    static let clusterPhoto: CGFloat = 80
    /// …on a `Suggestions` row, a little bigger, with the same tilt and overlap.
    static let clusterPhotoSuggestion: CGFloat = 88
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
    /// The wave strip under every torn surface (`EdgeFinal`: 4pt, scallops fitted to the width —
    /// ``WaveEdge``).
    static let tornEdgeHeight: CGFloat = 4
    /// The wordmark, in a receipt's footer row.
    static let wordmarkFooter: CGFloat = 18
    /// The wordmark, on a screen's header.
    static let wordmarkHeader: CGFloat = 30

    /// A dashed rule inside a receipt.
    static let ruleWidth: CGFloat = 1.5
    static let ruleDash: [CGFloat] = [4, 3]
    /// A dot leader between a line item and its score. `1.5px dotted` is round dots the width of the
    /// line, and the browser sets them on a **2.67pt pitch** — measured off the reference render
    /// rather than assumed, because a UA fits a whole number of dots into the run and lands a little
    /// tighter than two diameters. Paired with a round cap, so the near-zero dash draws as a circle
    /// rather than a 1.5-square: the dot's diameter is the line width.
    static let leaderDash: [CGFloat] = [0.01, 2.66]

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
