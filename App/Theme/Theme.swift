import SwiftUI

/// **The brand seam.** Every colour, type style, and spacing value in the app comes from here —
/// never from a literal at a call site. Today each token maps to a stock Apple semantic value, so
/// the app reads as pure native chrome (rule 1: brand is a coating, not a blocker). When Eamon
/// defines the brand, the `brand-designer` changes the mappings in this one file and the whole app
/// re-skins with no call-site edits.
///
/// Rules for adding a token:
/// - Name it by ROLE (`textSecondary`), never by appearance (`grey60`).
/// - Map it to a system semantic value, never a hardcoded RGB, until brand lands.
/// - If you're about to write `.padding(12)` or `.foregroundStyle(.gray)`, add a token instead.
public enum Theme {

    // MARK: - Colour

    public enum Color {
        /// App background behind scrolling content.
        public static let background = SwiftUI.Color(.systemBackground)
        /// Background behind grouped lists — the recessed tone that makes inset cards read as cards.
        public static let backgroundGrouped = SwiftUI.Color(.systemGroupedBackground)
        /// Cards, rows, and other raised surfaces.
        public static let surface = SwiftUI.Color(.secondarySystemBackground)
        /// Hairlines and dividers.
        public static let separator = SwiftUI.Color(.separator)
        /// Space held for media that hasn't loaded. A fill, so it stays visible on a card in dark
        /// mode where `surface` and the card are the same tone.
        public static let placeholder = SwiftUI.Color(.tertiarySystemFill)

        public static let textPrimary = SwiftUI.Color(.label)
        public static let textSecondary = SwiftUI.Color(.secondaryLabel)
        public static let textTertiary = SwiftUI.Color(.tertiaryLabel)

        /// The one expressive colour. Becomes the brand accent later.
        public static let accent = SwiftUI.Color.accentColor
        public static let destructive = SwiftUI.Color(.systemRed)
        public static let positive = SwiftUI.Color(.systemGreen)

        /// A filled (or half-filled) star in the rating gesture. Its own role rather than a reuse of
        /// `accent` at the call site, so the brand can make rating fill a different colour from
        /// buttons without touching a view.
        public static let ratingFilled = accent
        /// An unfilled star. Reads as "nothing here yet", not as a disabled control.
        public static let ratingEmpty = SwiftUI.Color(.tertiaryLabel)

        /// The receipt renders ONE deterministic pairing — it is exported as an image that leaves the
        /// device, so it must not follow the viewer's appearance setting. These are the only two
        /// colours in the app that are deliberately not dark-mode-adaptive.
        public static let receiptBackground = SwiftUI.Color(.sRGB, white: 0.98, opacity: 1)
        public static let receiptForeground = SwiftUI.Color(.sRGB, white: 0.08, opacity: 1)
        /// Subordinate text on the receipt (date, handle, footer band).
        public static let receiptSecondary = SwiftUI.Color(.sRGB, white: 0.42, opacity: 1)
    }

    // MARK: - Type

    /// Dynamic Type ramp. Always a system text style so accessibility sizes work for free.
    public enum Text {
        public static let screenTitle = Font.largeTitle.weight(.bold)
        public static let sectionTitle = Font.title3.weight(.semibold)
        public static let itemTitle = Font.headline
        /// A number that carries a screen: an aggregate score, a count.
        public static let metric = Font.title2.weight(.semibold)
        public static let body = Font.body
        public static let detail = Font.subheadline
        public static let caption = Font.footnote
        /// A score shown inside a list row. Monospaced digits so a column of scores doesn't jitter
        /// as rows scroll. (The large receipt/card score numerals are separate tokens, added with
        /// the surfaces that need them.)
        public static let rowScore = Font.subheadline.weight(.medium).monospacedDigit()
        /// The live readout beside the rating gesture and the numeral on a dish card. Monospaced so
        /// the number doesn't shuffle sideways as a finger scrubs across half-steps.
        public static let scoreNumeral = Font.title2.weight(.semibold).monospacedDigit()
        /// The receipt's headline score — the largest element on the artifact (§5.2).
        public static let receiptScore = Font.largeTitle.weight(.bold)
    }

    // MARK: - Spacing

    /// 4pt grid. Use the role names, not the numbers.
    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 8
        public static let regular: CGFloat = 12
        public static let comfortable: CGFloat = 16
        public static let loose: CGFloat = 24
        public static let section: CGFloat = 32
    }

    // MARK: - Shape

    public enum Radius {
        public static let control: CGFloat = 10
        public static let card: CGFloat = 16
        public static let sheet: CGFloat = 24
        /// Dish photography. Its own role so the brand can square photos off without squaring cards.
        public static let photo: CGFloat = card
        /// The receipt artifact's corner.
        public static let receipt: CGFloat = 20
    }

    /// Fixed sizes for the few things that can't size themselves from content.
    public enum Size {
        /// Square list-row thumbnail (a dish in a restaurant's list).
        public static let thumbnail: CGFloat = 56
        /// One star in a rating row. A size, not a font, so stars line up with any Dynamic Type.
        public static let star: CGFloat = 13
        /// Byline avatar in a list row.
        public static let avatarSmall: CGFloat = 28

        /// Height of the rating gesture's hit area (§2.1). Far taller than the glyphs it contains:
        /// the target is a thumb crossing a track, not five small buttons.
        public static let ratingTrackHeight: CGFloat = 64
        /// Slop past each end of the rating track (§2.1). Leading slop maps entirely to 0.5, so the
        /// lowest score is reachable without landing exactly on the first glyph.
        public static let ratingHitSlop: CGFloat = 24

        /// The exported receipt image (§5.3). 4:5 — the tallest a share sheet, an iMessage bubble and
        /// an Instagram feed post all render without cropping. One constant, one export size.
        public static let receiptExport = CGSize(width: 1080, height: 1350)
        /// Scale factor for `ImageRenderer` on the receipt (§5.3).
        public static let receiptExportScale: CGFloat = 3
    }

    /// Aspect ratios for media. Dish photos are presented 4:3 everywhere — the shape a plate reads
    /// best in, and the one the receipt reuses — so a photo never re-crops between surfaces and a
    /// list of dishes reads as a column, not a ransom note.
    public enum Ratio {
        public static let photo: CGFloat = 4.0 / 3.0
    }
}
