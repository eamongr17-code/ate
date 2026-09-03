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
        // The design language allows exactly THREE background tones (design-language §1.3). A fourth
        // is how every screen ends up looking like every other screen.

        /// The **plane**: content that is a stream of peers sits directly on this, parted by
        /// hairlines. Feed, Diary, the review stream on a dish.
        public static let background = SwiftUI.Color(.systemBackground)
        /// The recessed ground under **groups** (`.insetGrouped` lists) — the tone that makes an
        /// inset section read as a raised set of rows.
        public static let backgroundRecessed = SwiftUI.Color(.systemGroupedBackground)
        /// The **card** — and only the card: the entry view's review, a compose card on the log
        /// canvas. A card is never in a list of cards (§1.1).
        ///
        /// `secondarySystemGroupedBackground`, not `secondarySystemBackground`, and the pairing is
        /// load-bearing: on `backgroundRecessed` those two are the SAME colour in light mode, so the
        /// card the spec asked for rendered as nothing at all on device. The corollary is a rule:
        /// **a card always sits on `backgroundRecessed`.** A card on the plane would be white on
        /// white — which is fine, because a plane carries streams, and a stream has no cards.
        public static let surfaceCard = SwiftUI.Color(.secondarySystemGroupedBackground)
        /// The fill behind a **dish tile** — the small square that stands in for a dish with no
        /// photo. A fill, not a background, so it stays visible on a card as well as on the plane.
        public static let surfaceTile = SwiftUI.Color(.tertiarySystemFill)
        /// Hairlines and dividers.
        public static let separator = SwiftUI.Color(.separator)
        /// Space held for media that hasn't loaded. A fill, so it stays visible on a card in dark
        /// mode where `surfaceCard` and the card are the same tone.
        public static let placeholder = SwiftUI.Color(.tertiarySystemFill)
        /// The redaction fill under a skeleton (§5). Quieter than `placeholder`: a skeleton is a
        /// promise, not a hole.
        public static let skeleton = SwiftUI.Color(.quaternarySystemFill)

        public static let textPrimary = SwiftUI.Color(.label)
        public static let textSecondary = SwiftUI.Color(.secondaryLabel)
        public static let textTertiary = SwiftUI.Color(.tertiaryLabel)

        /// Letterforms on a dish tile. Subordinate by design — a tile is an anchor, not a headline.
        public static let tileForeground = SwiftUI.Color(.tertiaryLabel)

        /// **BRAND SEAM (flagged).** The monogram tile picks one of these steps deterministically
        /// from the dish's canonical UUID. Today it is Apple's own neutral ramp, so an imageless
        /// menu reads as tonal texture and nothing else; when the brand lands, the `brand-designer`
        /// replaces the *contents* of this array (and only this array) with the brand's tile hues.
        /// The index function lives in `AteKit.DishTileIdentity` and is ours, not the brand's.
        public static let tilePalette: [SwiftUI.Color] = [
            SwiftUI.Color(.systemGray6),
            SwiftUI.Color(.systemGray5),
            SwiftUI.Color(.systemGray4),
            SwiftUI.Color(.systemGray3),
            SwiftUI.Color(.systemGray2),
            SwiftUI.Color(.systemGray)
        ]

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
        /// device, so it must not follow the viewer's appearance setting. These are the only colours
        /// in the app that are deliberately not dark-mode-adaptive.
        public static let receiptBackground = SwiftUI.Color(.sRGB, white: 0.98, opacity: 1)
        public static let receiptForeground = SwiftUI.Color(.sRGB, white: 0.08, opacity: 1)
        /// Subordinate text on the receipt (date, handle, footer band).
        public static let receiptSecondary = SwiftUI.Color(.sRGB, white: 0.42, opacity: 1)
        /// The rule above the receipt's tag band. Non-adaptive for the same reason as the rest of
        /// the receipt palette.
        public static let receiptRule = SwiftUI.Color(.sRGB, white: 0.88, opacity: 1)
    }

    // MARK: - Type

    /// Dynamic Type ramp. Always a system text style so accessibility sizes work for free — with one
    /// documented exception, the receipt, which is an image at a fixed pixel size and must not
    /// reflow under the reader's text-size setting.
    public enum Text {
        public static let screenTitle = Font.largeTitle.weight(.bold)
        public static let sectionTitle = Font.title3.weight(.semibold)
        public static let itemTitle = Font.headline
        /// A number that carries a screen: an aggregate score, a count.
        public static let metric = Font.title2.weight(.semibold)
        /// The aggregate hero at the top of a dish or restaurant — the biggest number on a read
        /// screen, one step above `metric`.
        public static let heroMetric = Font.title.weight(.semibold).monospacedDigit()
        public static let body = Font.body
        public static let detail = Font.subheadline
        public static let caption = Font.footnote
        /// The "who and when" strip above a review in a stream.
        public static let streamByline = Font.subheadline
        /// A score shown inside a list row. Monospaced digits so a column of scores doesn't jitter
        /// as rows scroll.
        public static let rowScore = Font.subheadline.weight(.medium).monospacedDigit()
        /// The live readout beside the rating gesture and the numeral on a dish card. Monospaced so
        /// the number doesn't shuffle sideways as a finger scrubs across half-steps.
        public static let scoreNumeral = Font.title2.weight(.semibold).monospacedDigit()

        // MARK: Tile type
        //
        // A tile's type is sized by the WELL it fills, not by the reader's Dynamic Type: a monogram
        // that grew with the text-size setting would burst a 44pt square. These are therefore
        // functions of the well, and the ratios — not the sizes — are the tokens.

        /// Variant A: the dish's own name, over-scaled and clipped by the well.
        public static func tileTypographic(well: CGFloat) -> Font {
            .system(size: well * tileTypographicRatio, weight: .semibold).smallCaps()
        }

        /// Variant B: two letters, centred in the well.
        public static func tileMonogram(well: CGFloat) -> Font {
            .system(size: well * tileMonogramRatio, weight: .semibold)
        }

        /// Deliberately over 1/3 of the well: the name is meant to run out of the square.
        private static let tileTypographicRatio: CGFloat = 0.42
        private static let tileMonogramRatio: CGFloat = 0.38

        // MARK: Receipt type (the fixed-size exception)

        /// The receipt's hero numeral. Fixed points, not a text style: the artifact is rendered at
        /// 1080×1350 and shared as an image — Dynamic Type must not reflow a picture.
        public static let receiptScoreNumeral = Font.system(size: 88, weight: .bold).monospacedDigit()
        /// The `/5` beside it, baseline-aligned at roughly 40% of the numeral.
        public static let receiptScoreScale = Font.system(size: 34, weight: .bold)
        /// The dish name under the score (or the restaurant name on a multi-dish receipt).
        public static let receiptDishName = Font.system(size: 30, weight: .semibold)
        /// The place line, and a multi-dish receipt's per-dish rows.
        public static let receiptSecondary = Font.system(size: 20, weight: .regular)
        /// The tag band: handle, date, `ate`.
        public static let receiptFooter = Font.system(size: 14, weight: .regular)
    }

    // MARK: - Spacing

    /// 4pt grid. Use the role names, not the numbers. No vertical value in the app is off this scale.
    public enum Spacing {
        /// Between glyphs (stars in a row).
        public static let hairline: CGFloat = 2
        /// Label ↔ value.
        public static let tight: CGFloat = 4
        /// Two lines of one thought.
        public static let snug: CGFloat = 8
        /// Zones of one unit.
        public static let regular: CGFloat = 12
        /// **THE horizontal screen margin**, everywhere: stream rows, card padding, screen insets.
        public static let gutter: CGFloat = 16
        /// Between units.
        public static let loose: CGFloat = 24
        /// Above a section header.
        public static let section: CGFloat = 32

        /// Vertical padding on a row of a stream. Two rows therefore sit `loose` apart with a
        /// hairline between them — the rhythm that makes a plane read as a stream (§1.5).
        public static let streamRow: CGFloat = 12
    }

    // MARK: - Shape

    /// Radius follows the surface's SIZE, not its content (§1.4).
    public enum Radius {
        /// ≤64pt squares: dish tiles, thumbnails, small controls.
        public static let tile: CGFloat = 10
        /// Full-width wells — the card, and the photo inside it.
        public static let card: CGFloat = 16
        /// The receipt artifact's corner.
        public static let receipt: CGFloat = 20
        /// System sheet corner.
        public static let sheet: CGFloat = 24
    }

    /// Fixed sizes for the few things that can't size themselves from content.
    public enum Size {
        /// The small filled gutter tile — a diary row's dish anchor.
        public static let tileSmall: CGFloat = 44
        /// Square list-row thumbnail (a dish in a restaurant's list, a search result, a sibling row).
        public static let thumbnail: CGFloat = 56
        /// The leading tile in the feed's dense row variant (§9's question #2) — big enough to be a
        /// picture rather than an icon, small enough to fit twice the reviews on a screen.
        public static let tileFeedLeading: CGFloat = 72
        /// One star in a rating row. A size, not a font, so stars line up with any Dynamic Type.
        public static let star: CGFloat = 13
        /// The left gutter a person-led review stream hangs off, and the avatar that fills it.
        public static let avatarGutter: CGFloat = 44
        /// Byline avatar in a stream row's identity strip.
        public static let avatarByline: CGFloat = 20

        /// One device pixel. A hairline is a *pixel* rule, never `Divider()`'s 1 logical point —
        /// at 3× that is three times too heavy and is what makes a list look like a spreadsheet.
        /// The fallback matters: `displayScale` is 0 in some render contexts (`ImageRenderer`).
        public static func hairline(displayScale: CGFloat) -> CGFloat {
            displayScale > 0 ? 1 / displayScale : 0.5
        }

        /// Height of the rating gesture's hit area (§2.1). Far taller than the glyphs it contains:
        /// the target is a thumb crossing a track, not five small buttons.
        public static let ratingTrackHeight: CGFloat = 64
        /// Slop past each end of the rating track (§2.1). Leading slop maps entirely to 0.5, so the
        /// lowest score is reachable without landing exactly on the first glyph.
        public static let ratingHitSlop: CGFloat = 24

        /// The rule above the receipt's tag band. A fixed logical thickness, not a device pixel:
        /// the receipt is art rendered at 3×, where one device pixel would all but vanish.
        public static let receiptRule: CGFloat = 1

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
