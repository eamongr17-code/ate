import CoreText
import SwiftUI

/// **The voices** — and the only place in the app that is allowed to name a font.
///
/// Since 7 Nov 2026 (Eamon: the serif-on-beige look read as Claude's own app):
///
/// - **Radio Canada Big** — headings: screen and page titles, places, dishes, list names. Bold.
/// - **Radio Canada** — controls (600, 15), labels, meta, scores and avatar letters. The text cut of
///   the same family, so the furniture shares the headings' tapered strokes.
/// - **Spectral** — the person's own words, everywhere they appear, set 2% tight.
/// - **Spline Sans Mono** — inside receipts, and nowhere else. Its zero is plain, not slashed.
///
/// Radio Canada Big, Radio Canada and Spline Sans Mono ship as variable fonts, so a weight is a point
/// on the `wght` axis rather than a separate file. Spectral ships as static cuts (regular, medium and
/// their italics). None of the four has an optical-size axis.
///
/// Everything degrades: if the font files are missing from the bundle, each voice falls back to a
/// system design (`.serif` for the words, `.monospaced` for receipts, the system sans for chrome) and
/// the app still lays out correctly. Dynamic Type scaling is applied either way.
enum AteVoice: Sendable {
    /// Radio Canada Big — the words a screen is about: titles, places, dishes, list names. Not numbers.
    case heading
    /// Radio Canada — controls, labels, meta, scores. The app's furniture.
    case display
    /// Spectral — the person's words. Never used for chrome.
    case prose
    /// Spline Sans Mono — receipts only.
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

// MARK: - Resolution

/// Turns an ``AteTextStyle`` into a real font. The single point where a family name is spoken.
enum AteFont {

    /// How much heavier than its nominal weight the prose voice is drawn on the variable axis.
    ///
    /// Newsreader needed +80 to match the browser render Eamon judged (Core Graphics does not
    /// stem-darken a serif the way a browser does). Spectral ships as static cuts, so there is no axis
    /// to move and the words are drawn at the weight the style names; kept at zero so a variable prose
    /// face added later starts from the design's own number.
    static let proseWeightCompensation: CGFloat = 0

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

    // MARK: Private

    /// The face at its design size, with **its variable axes pinned by us**: `wght` from the style
    /// (inside the face's own range — a title asks for 800, Radio Canada Big stops at 700) and `opsz`
    /// from `opticalSize` when a face has one. Italic runs come off a real italic file, never a
    /// slanted roman.
    private static func base(for style: AteTextStyle, opticalSize: CGFloat) -> UIFont {
        let registry = AteFontRegistry.shared
        guard let face = registry.face(for: style.voice, italic: style.italic) else {
            return fallback(for: style)
        }
        guard let named = UIFont(name: face.postScriptName(forWeight: style.weight), size: style.size) else {
            return fallback(for: style)
        }
        guard let axes = face.variationAxes else { return named }
        var weight = drawnWeight(for: style)
        if let range = face.weightRange { weight = min(max(weight, range.lowerBound), range.upperBound) }
        var variations: [Int: CGFloat] = [AteFontAxis.weight: weight]
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

    /// The weight the variable axis is actually set to — the design's, plus the prose compensation
    /// (zero for Spectral, which has no axis).
    private static func drawnWeight(for style: AteTextStyle) -> CGFloat {
        style.voice == .prose ? style.weight + proseWeightCompensation : style.weight
    }

    /// The safety net: system designs that stand in for each voice when the files are absent.
    private static func fallback(for style: AteTextStyle) -> UIFont {
        let weight = UIFont.Weight(wght: style.weight)
        let base = UIFont.systemFont(ofSize: style.size, weight: weight)
        let design: UIFontDescriptor.SystemDesign = switch style.voice {
        case .heading, .display: .default
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
