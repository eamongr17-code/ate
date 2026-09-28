import CoreText
import SwiftUI

/// **The three voices** — and the only place in the app that is allowed to name a font.
///
/// - **Bricolage Grotesque** — titles (800, tracking −3.5%, line-height 1.0) and controls (600, 15).
/// - **Newsreader** — the person's own words, everywhere they appear.
/// - **DM Mono** — inside receipts, and nowhere else.
///
/// The families ship as variable fonts, so a weight is a point on the `wght` axis rather than a
/// separate file, and the optical-size axis is driven from the actual point size (that is what `opsz`
/// is for: Bricolage at 13 is a different drawing from Bricolage at 40).
///
/// Everything degrades: if the font files are missing from the bundle, each voice falls back to a
/// system design (`.serif` for the words, `.monospaced` for receipts, the system sans for chrome) and
/// the app still lays out correctly. Dynamic Type scaling is applied either way.
enum AteVoice: Sendable {
    /// Bricolage Grotesque — titles, controls, labels, meta. The app's furniture.
    case display
    /// Newsreader — the person's words. Never used for chrome.
    case prose
    /// DM Mono — receipts only.
    case mono
}

/// One text style: a voice at a size, with the tracking and line height the design asks for, and the
/// system text style it scales against.
struct AteTextStyle: Equatable, Sendable {
    var voice: AteVoice
    /// Points at the default Dynamic Type size (`.large`) — the numbers in `design/v1`.
    var size: CGFloat
    /// A point on the `wght` axis: 800 titles, 700 buttons, 600 controls, 500 meta, 400 prose.
    var weight: CGFloat = 400
    var italic: Bool = false
    /// Tracking as a fraction of the em, the way the prototype's CSS writes it (`-.035em`).
    var trackingEm: CGFloat = 0
    /// Line height as a multiple of the size.
    var lineHeight: CGFloat = 1.3
    /// What Dynamic Type scales this against.
    var textStyle: Font.TextStyle = .body
    /// How far it is allowed to grow at accessibility sizes. Chrome that must stay inside a fixed
    /// well (a tab-bar label, a receipt's mono labels) is capped; prose never is.
    var maximumSize: CGFloat?
    var uppercase: Bool = false

    /// The line box this style asks for, in points. A `Text` gets it from `lineSpacing`, but a row
    /// built out of several views — a receipt's line item is a number, a name, a leader and a score
    /// — has to be given it as a height, or the rows stack at the font's own line height and the
    /// bill loses its rhythm (`.li` is `13px/1.65` = 21.45, and it came out 17).
    func lineBox(_ dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        // Not rounded: 13 × 1.65 is 21.45, and rounding it to 21 loses half a point per row — three
        // line items into a bill that is a point and a half short of the artboard.
        AteFont.size(for: self, dynamicTypeSize: dynamicTypeSize) * lineHeight
    }
}

// MARK: - The named styles
//
// Every size in `design/v1` appears here once. A view asks for a role; it never asks for a number.

extension AteTextStyle {

    // Titles — Bricolage 800. Tracking −3.5% above 30pt, −2.5% at slip sizes (the prototype
    // overrides `.h`'s letter-spacing for the 20/22pt place names).

    /// A screen's own name: "Feed", "You", "Search". 40pt.
    static let screenTitle = AteTextStyle(
        voice: .display, size: 40, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// The place at the head of its own page — the biggest type in the app, because on the place
    /// page the place is the whole subject. 44pt (`Restaurant.dc.html`).
    static let placeTitle = AteTextStyle(
        voice: .display, size: 44, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// A dish's aggregate, printed like a price on its own page. 64pt — the one number big enough
    /// to be read across a table (`Dish.dc.html`).
    static let dishScore = AteTextStyle(
        voice: .display, size: 64, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// A dish in the "what to order" list, and its score beside it. 17/24 — a menu line, not a
    /// slip's dish (20/26): the list is scanned, and the photo carries the weight.
    static let menuDish = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    static let menuScore = AteTextStyle(
        voice: .display, size: 24, weight: 800, trackingEm: -0.025, lineHeight: 1.0, textStyle: .title2
    )
    /// The place at the head of the entry page — the biggest type in the app after a screen's own
    /// name, because on an entry the place IS the title. 38pt.
    static let entryPlace = AteTextStyle(
        voice: .display, size: 38, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// The place at the head of a receipt. 32pt.
    static let receiptPlace = AteTextStyle(
        voice: .display, size: 32, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// A sheet's title. 30pt.
    static let sheetTitle = AteTextStyle(
        voice: .display, size: 30, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// A handle at the head of a profile. 32pt.
    static let profileTitle = AteTextStyle(
        voice: .display, size: 32, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// The one line an empty slip says. 34pt — it sits inside paper, not on the ground, so it is a
    /// step down from ``screenTitle``.
    static let emptyTitle = AteTextStyle(
        voice: .display, size: 34, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// The score a `Ratings` page is about, beside its stars. `.h` at 30.
    static let ratingsScore = AteTextStyle(
        voice: .display, size: 30, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// A number in a statement's cell: "142". 28pt.
    static let statValue = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.03, lineHeight: 1.0, textStyle: .title2
    )
    /// A pushed page's own name, beside a back arrow: "From your photos". 24pt.
    static let pageTitle = AteTextStyle(
        voice: .display, size: 24, weight: 800, trackingEm: -0.025, lineHeight: 1.0, textStyle: .title2
    )
    /// "Pick a handle." — first run's one question, at the size of a place heading its own page.
    static var handleTitle: AteTextStyle { placeTitle }
    /// "Your ratings" — `.h` at 38 on `Ratings.dc.html`, the entry page's title size, not a tab's 40.
    static var ratingsTitle: AteTextStyle { entryPlace }
    /// What is typed into the handle field. `.h` at 30 — and at **−2%**, not `.h`'s own −3.5%:
    /// `Handle.dc.html` overrides the tracking on that one input, because a handle is read letter
    /// by letter and the title's tight setting closes `@e` up into one shape.
    static let handleField = AteTextStyle(
        voice: .display, size: 30, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title
    )
    /// A place heading a group of rows — the Saved shelf's place heads. 22pt.
    static let slipPlace = AteTextStyle(
        voice: .display, size: 22, weight: 800, trackingEm: -0.025, lineHeight: 1.05, textStyle: .title2
    )
    /// **A dish in a slip's stack. 20pt** — the item itself, and the largest thing on a slip after
    /// its score. It wraps rather than truncating, so this never gets a line limit.
    static let slipDish = AteTextStyle(
        voice: .display, size: 20, weight: 800, trackingEm: -0.03, lineHeight: 1.05, textStyle: .title3
    )
    /// …and the score beside it, printed like a price. 26pt at `.h`'s own line height of 1.
    static let slipScore = AteTextStyle(
        voice: .display, size: 26, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )

    // Controls — Bricolage 600/700.

    /// The default control label: segment, chip, row. 15pt.
    static let control = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// A row's own name in a list, and what is typed into a sheet's search field. `.ui` at 17.
    static let rowTitle = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// `Search`'s own field: `.ui` 17 at `font-weight:500`, lighter than a sheet's (`rowTitle`).
    static let searchField = AteTextStyle(
        voice: .display, size: 17, weight: 500, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// A smaller control label: segments, toolbar keys, handles. 14pt.
    static let controlSmall = AteTextStyle(
        voice: .display, size: 14, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .subheadline
    )
    /// The one ink pill per sheet, and the Share button. 16pt/700.
    static let button = AteTextStyle(
        voice: .display, size: 16, weight: 700, trackingEm: -0.01, lineHeight: 1.2, textStyle: .body
    )
    /// A tab bar label. 10.5pt, bold when the tab is current. Capped: it lives in a 66pt pill.
    static let tabLabel = AteTextStyle(
        voice: .display, size: 10.5, weight: 500, trackingEm: 0, lineHeight: 1.2,
        textStyle: .caption2, maximumSize: 14
    )
    static let tabLabelActive = AteTextStyle(
        voice: .display, size: 10.5, weight: 700, trackingEm: 0, lineHeight: 1.2,
        textStyle: .caption2, maximumSize: 14
    )
    /// The count in the journal header's coral badge. 11pt, capped — it lives in an 18pt disc.
    static let badge = AteTextStyle(
        voice: .display, size: 11, weight: 600, trackingEm: -0.01, lineHeight: 1.2,
        textStyle: .caption2, maximumSize: 13
    )
    /// "2h", "5 photos", a date above a slip. 13pt/500.
    static let meta = AteTextStyle(
        voice: .display, size: 13, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
    /// A dish's name under its tile in a small cluster — "Your 5.0s". `.meta` at 12, in full ink:
    /// the name is the item, not a caption about it.
    static let tileCaption = AteTextStyle(
        voice: .display, size: 12, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .caption
    )
    /// The place on a slip's place line — `.meta`'s size in the control weight, in full ink.
    static let slipPlaceName = AteTextStyle(
        voice: .display, size: 13, weight: 600, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
    /// A dietary tag's code in its linen chip (`DietTagsB`): Bricolage 600 at 10.5, capitals,
    /// tracking 6%, `line-height:1`. Capped — the chip is a fixed 18pt.
    static let dietTag = AteTextStyle(
        voice: .display, size: 10.5, weight: 600, trackingEm: 0.06, lineHeight: 1.0,
        textStyle: .caption2, maximumSize: 13, uppercase: true
    )
    /// The dish on the score slider's panel (`RaterSize`): `.h` at 22, `-.03em`, `line-height:1.05`
    /// — the slip's dish voice, a step up, so the name and the number read on one scale.
    static let sliderDish = AteTextStyle(
        voice: .display, size: 22, weight: 800, trackingEm: -0.03, lineHeight: 1.05, textStyle: .title2
    )
    /// …and the live numeral beside it: `.h` at 28, `-.02em`, tabular.
    static let sliderScore = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )
    /// The letter on a photo-less dish's tile (`NoPhotoA`): `.h` 800 at 26 on a 56 tile, `-.02em`,
    /// scaled with the tile and never with Dynamic Type — it is a picture of the dish, not a label.
    static func dishInitial(tile side: CGFloat) -> AteTextStyle {
        AteTextStyle(
            voice: .display, size: side * 26 / 56, weight: 800, trackingEm: -0.02, lineHeight: 1.0,
            textStyle: .title2, maximumSize: side * 26 / 56
        )
    }
    /// A letter in a byline's avatar circle. No tracking — a monogram is centred, not set.
    static let avatarInitial = AteTextStyle(
        voice: .display, size: 12, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .caption, maximumSize: 16
    )
    /// …and in the 36pt disc beside a dish review. 16pt, capped for the same reason.
    static let avatarInitialMedium = AteTextStyle(
        voice: .display, size: 16, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .body, maximumSize: 20
    )
    /// …and in the 76pt disc at the head of a profile. 34pt, capped for the same reason.
    static let avatarMonogram = AteTextStyle(
        voice: .display, size: 34, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .title, maximumSize: 44
    )

    // The person's words — Newsreader.

    /// The composer: the biggest the words ever are. 19pt.
    static let composerProse = AteTextStyle(
        voice: .prose, size: 19, weight: 400, lineHeight: 1.5, textStyle: .body
    )
    /// The one line an empty slip or Welcome says under its title. 17pt — `.prose`'s own 1.5.
    static let proseLarge = AteTextStyle(
        voice: .prose, size: 17, weight: 400, lineHeight: 1.5, textStyle: .body
    )
    /// The words in a journal slip. 16pt at `.prose`'s 1.5 — the entry page sets 1.45 by hand, and
    /// the two really are different in the markup.
    static let slipProse = AteTextStyle(
        voice: .prose, size: 16, weight: 400, lineHeight: 1.5, textStyle: .body
    )
    /// Welcome's promise, set italic and centred. 19pt.
    static let proseQuote = AteTextStyle(
        voice: .prose, size: 19, weight: 400, italic: true, lineHeight: 1.3, textStyle: .body
    )
    /// The words on their own page (Entry) and in a journal slip. 16pt.
    static let prose = AteTextStyle(
        voice: .prose, size: 16, weight: 400, lineHeight: 1.45, textStyle: .body
    )
    /// The words in a feed slip, beside a thumbnail. 15pt.
    static let proseCompact = AteTextStyle(
        voice: .prose, size: 15, weight: 400, lineHeight: 1.4, textStyle: .body
    )

    // Receipts — DM Mono, and only here. Dish rows and scores only: no note under a line, ever.

    /// A receipt line item. 13pt.
    static let receiptLine = AteTextStyle(
        voice: .mono, size: 13, weight: 400, lineHeight: 1.65, textStyle: .footnote, maximumSize: 20
    )
    /// The score at the end of a line item — the "price" column. 13pt/500.
    static let receiptScore = AteTextStyle(
        voice: .mono, size: 13, weight: 500, lineHeight: 1.65, textStyle: .footnote, maximumSize: 20
    )
    /// The numerals under the ratings histogram. 10pt DM Mono, plain — the only mono outside a
    /// receipt, because a chart's scale is a printed measure and reads as one.
    static let scaleLabel = AteTextStyle(
        voice: .mono, size: 10, weight: 400, lineHeight: 1.35, textStyle: .caption2, maximumSize: 14
    )
    /// A receipt label: the address, `ORDER #0142`, `3 DISHES`, `@eamon`. 11pt, uppercase, +8%.
    static let receiptLabel = AteTextStyle(
        voice: .mono, size: 11, weight: 400, trackingEm: 0.08, lineHeight: 1.35,
        textStyle: .caption2, maximumSize: 16, uppercase: true
    )
}

// MARK: - Resolution

/// Turns an ``AteTextStyle`` into a real font. The single point where a family name is spoken.
enum AteFont {

    /// **Newsreader is drawn heavier than the 400 the design names.**
    ///
    /// The prototype's 400 and ours are the same outlines — "tagliatelle" at 17 advances identically
    /// in both — but a browser gamma-corrects and stem-darkens text and Core Graphics does not, so
    /// the same file comes off an iPhone about a fifth less inked: 30.1% coverage and a 5px stem in
    /// the render against 25.7% and 4px on the device, measured at 3x. It is a serif problem and not
    /// a rendering-stack problem in general — DM Mono on the same page is within half a percent.
    ///
    /// Eamon judged the render, so the render is the target and the axis is the only lever that
    /// reaches it. The cost is bought knowingly: heavier is wider, and the words wrap a little
    /// sooner than the artboard's do.
    ///
    /// Only the **prose** voice is compensated; it is added to the style's own weight, so a bold
    /// Newsreader added later still lands a notch above its nominal. And only the variable axis is
    /// moved — the system-serif fallback keeps the design's weight, because it has no gamma to undo.
    static let proseWeightCompensation: CGFloat = 80

    /// The resolved `UIFont` — needed directly by the composer, which has to put fonts into an
    /// `NSAttributedString`, and by anything drawing text into an image.
    ///
    /// `opsz` is driven from the size the glyphs are **drawn** at, not from the design's number:
    /// the prototype sets `font-optical-sizing:auto`, which tracks the used font-size, and a reader
    /// at an accessibility size would otherwise get 24pt glyphs cut for 17.
    static func uiFont(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: UIFont.TextStyle(style.textStyle))
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let drawn = min(
            metrics.scaledValue(for: style.size, compatibleWith: traits),
            style.maximumSize ?? .greatestFiniteMagnitude
        )
        let base = base(for: style, opticalSize: drawn)
        let scaled = if let maximum = style.maximumSize {
            metrics.scaledFont(for: base, maximumPointSize: maximum, compatibleWith: traits)
        } else {
            metrics.scaledFont(for: base, compatibleWith: traits)
        }
        // `scaledFont` rounds to a whole point. The design has fractional sizes — a score token is
        // `.78em` (12.48 in a slip, 13.26 on the entry page), a tab label 10.5 — and rounding them
        // printed every token's figures about 4% small against the artboard's `.tok`. The font keeps
        // its Dynamic Type identity; only the size is put back to the one computed above.
        return scaled.withSize(drawn)
    }

    static func font(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> Font {
        Font(uiFont(for: style, dynamicTypeSize: dynamicTypeSize))
    }

    /// The point size after Dynamic Type — what tracking and line spacing are computed from.
    static func size(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        uiFont(for: style, dynamicTypeSize: dynamicTypeSize).pointSize
    }

    /// Whether the bundled families are actually present. Shown in the debug gallery so a missing
    /// font is visible as a fact rather than guessed at from a screenshot.
    static var bundledFamiliesAreAvailable: Bool {
        AteFontRegistry.shared.isAvailable
    }

    static var registeredFaceNames: [String] {
        AteFontRegistry.shared.faceNames
    }

    // MARK: Private

    /// The face at its design size, with **both variable axes pinned by us**: `wght` from the style
    /// (400 for every Newsreader run, 800 for a title) and `opsz` from `opticalSize`.
    ///
    /// Pinned rather than left to Core Text's automatic optical sizing, which happens to agree at the
    /// default text size and is silent when it does not. The bundled files are the variable ones, so
    /// the italic runs come off `Newsreader-Italic-Variable`, never a slanted roman.
    private static func base(for style: AteTextStyle, opticalSize: CGFloat) -> UIFont {
        let registry = AteFontRegistry.shared
        guard let face = registry.face(for: style.voice, italic: style.italic) else {
            return fallback(for: style)
        }
        guard let named = UIFont(name: face.postScriptName(forWeight: style.weight), size: style.size) else {
            return fallback(for: style)
        }
        guard let axes = face.variationAxes else { return named }
        var variations: [Int: CGFloat] = [AteFontAxis.weight: drawnWeight(for: style)]
        if let opsz = face.opticalSizeRange {
            variations[AteFontAxis.opticalSize] = min(max(opticalSize, opsz.lowerBound), opsz.upperBound)
        }
        let supported = variations.filter { axes.contains($0.key) }
        guard supported.isEmpty == false else { return named }
        let descriptor = named.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                Dictionary(uniqueKeysWithValues: supported.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) })
        ])
        return UIFont(descriptor: descriptor, size: style.size)
    }

    /// The weight the variable axis is actually set to — the design's, plus Newsreader's gamma
    /// compensation. Both faces of the family, roman and italic, since both are drawn by the same
    /// rasteriser.
    private static func drawnWeight(for style: AteTextStyle) -> CGFloat {
        style.voice == .prose ? style.weight + proseWeightCompensation : style.weight
    }

    /// The safety net: system designs that stand in for each voice when the files are absent.
    private static func fallback(for style: AteTextStyle) -> UIFont {
        let weight = UIFont.Weight(wght: style.weight)
        let base = UIFont.systemFont(ofSize: style.size, weight: weight)
        let design: UIFontDescriptor.SystemDesign = switch style.voice {
        case .display: .default
        case .prose: .serif
        case .mono: .monospaced
        }
        var descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        if style.italic, let italic = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = italic
        }
        return UIFont(descriptor: descriptor, size: style.size)
    }
}

/// The OpenType variation axes we drive, as their four-byte tags.
enum AteFontAxis {
    /// `wght`
    static let weight = 0x7767_6874
    /// `opsz`
    static let opticalSize = 0x6F70_737A
}

// MARK: - Bridges

private extension UIFont.Weight {
    /// The nearest system weight to a `wght` axis value, for the fallback path.
    init(wght: CGFloat) {
        self = switch wght {
        case ..<250: .ultraLight
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

private extension UIFont.TextStyle {
    // A one-to-one table between two frameworks' enums. Dense by nature; splitting it would only
    // hide half the mapping.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ style: Font.TextStyle) {
        self = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension UIContentSizeCategory {
    // As above: the Dynamic Type ramp is twelve steps, and a table is the clearest form it takes.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ size: DynamicTypeSize) {
        self = switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

// MARK: - Applying a style

extension View {
    /// Sets the voice, size, tracking, line height and casing for a subtree. **The only way text is
    /// styled in this app** — no view calls `.font(...)` directly.
    func ateText(_ style: AteTextStyle) -> some View {
        modifier(AteTextModifier(style: style))
    }

}

/// Reads `dynamicTypeSize` from the environment, which is what makes the whole ramp re-lay out when
/// the reader changes their text size — a font resolved without reading it would go stale.
private struct AteTextModifier: ViewModifier {
    let style: AteTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let font = AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize)
        return content
            .font(Font(font))
            .tracking(font.pointSize * style.trackingEm)
            .lineSpacing(max(0, font.pointSize * style.lineHeight - font.lineHeight))
            .textCase(style.uppercase ? .uppercase : nil)
    }
}
