import CoreGraphics

/// **Every sheet's header, in one place** — where the close disc, the primary disc and the title sit.
/// The scaffold lays its header out from this and nothing else, so no sheet can move its X: the close
/// disc is the same frame on a pick sheet, a choice sheet and a sheet with a primary action, the
/// primary mirrors it top right, and the title starts at the same y under that row.
public enum SheetHeaderGeometry {
    /// The kinds of sheet the scaffold draws. They differ below the header, never in it.
    public enum Variant: CaseIterable, Sendable {
        /// Picks one row and closes on the tap: close, title, rows.
        case pick
        /// Applies a choice: close, title, controls, the ink pill at the foot.
        case choice
        /// Carries a primary action top right (the ink tick, Share).
        case primary
    }

    public struct Layout: Equatable, Sendable {
        public let close: CGRect
        public let primary: CGRect?
        /// Where the title's line box starts.
        public let titleTop: CGFloat
        public let titleLeading: CGFloat
    }

    /// A corner disc's side.
    public static let disc: CGFloat = 44
    /// `.top{left:16px; right:16px; top:14px}` — clear of the system grabber (which ends at 11).
    public static let cornerInset: CGFloat = 16
    public static let cornerTop: CGFloat = 14
    /// 14 under the discs: the title's top at 72.
    public static let titleGap: CGFloat = 14
    /// The title and everything under it sit on the screen gutter.
    public static let gutter: CGFloat = 20

    public static var titleTop: CGFloat { cornerTop + disc + titleGap }

    public static func layout(for variant: Variant, width: CGFloat) -> Layout {
        let close = CGRect(x: cornerInset, y: cornerTop, width: disc, height: disc)
        let primary = variant == .primary
            ? CGRect(x: width - cornerInset - disc, y: cornerTop, width: disc, height: disc)
            : nil
        return Layout(close: close, primary: primary, titleTop: titleTop, titleLeading: gutter)
    }
}
