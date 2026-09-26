import AteKit
import SwiftUI
import UIKit

/// **One attributed string for tokens-in-prose**, built once and used by both the read-only label and
/// the editable text view — so the words in a journal slip and the words in the composer are the same
/// drawing, not two that have to be kept in step.
///
/// Why UIKit text at all, for something read-only: a token pill is about 1.2em tall, which is what the
/// design draws. SwiftUI's `Text` takes an image run's full height as the line's ascent and adds any
/// baseline offset to its descent, so every line containing a pill comes out five to eight points
/// taller than the ones around it and the paragraph loses its rhythm. `NSParagraphStyle` sets an exact
/// line height that an attachment sits *inside*, exactly the way the prototype's CSS `line-height`
/// does. That is the whole reason this seam exists.
@MainActor
struct InlineTokenAttributes {
    var style: AteTextStyle
    var palette: AtePalette
    var dynamicTypeSize: DynamicTypeSize
    var displayScale: CGFloat
    /// Carried explicitly because the pill is rasterised by `ImageRenderer`, which has no trait
    /// collection to inherit a scheme from. See ``TokenPill``.
    var colorScheme: ColorScheme = .light
    /// The token whose slider is open. `ComposerStars` rings it — `box-shadow:0 0 0 2px #24141F` —
    /// so the panel and the pill it is scoring are visibly the same thing.
    var selectedTokenID: UUID?
    /// Where the words stop being settled, in **plain** offsets. `ComposerVoice.dc.html` draws the tail
    /// the recogniser is still revising in `--muted`, so it reads as "not yet yours" while the rest of
    /// the sentence is in full ink. `nil` everywhere else, which is everywhere the words are finished.
    var volatileFromPlainOffset: Int?

    var font: UIFont { AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize) }

    /// **Half the leading, the half that belongs under the words.**
    ///
    /// CSS splits the difference between a line box and the font's own box evenly, above and below
    /// the glyphs ("half-leading"); TextKit, handed a clamped line height, puts all of it above and
    /// sits the glyphs on the floor of the box. At `.proseLarge` that is 4.25pt, and it is exactly
    /// how far every line of read-only prose was drawn below the render.
    ///
    /// Zero when the font's box is already taller than the line box — a tight line height has no
    /// leading to split, and the clamp then behaves exactly as it did before.
    var halfLeading: CGFloat {
        let font = font
        return max(0, (font.pointSize * style.lineHeight - (font.ascender - font.descender)) / 2)
    }

    /// How tall these words are at this width. The composer hangs its photo cluster off the bottom
    /// of the sentence, and measuring the *same* attributed string the editor draws is the only way
    /// the two can agree about where that is.
    ///
    /// Plus the half-leading TextKit leaves off the last line: `lineSpacing` sits *between* lines, so
    /// the laid-out text is that much shorter than the block CSS would give it. The words occupy
    /// whole line boxes — what hangs off the bottom of them hangs where the artboard puts it.
    func height(for composition: EntryComposition, width: CGFloat) -> CGFloat {
        guard width > 0, composition.isEmpty == false else { return 0 }
        return (attributedString(for: composition).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height + halfLeading).rounded(.up)
    }

    /// The attributes every run carries: the voice, the ink, an exact line height, and the design's
    /// tracking.
    func base() -> [NSAttributedString.Key: Any] {
        let font = font
        let paragraph = NSMutableParagraphStyle()
        // The line box, minus the half of its leading that belongs *below* the words — which is then
        // put back as the space between lines. Same rhythm as a single clamp (a line still advances
        // by exactly `size × lineHeight`), but the glyphs sit where CSS draws them instead of on the
        // floor of the box, and the caret, the selection and the pills all move with them because
        // the line fragment itself is what moved. `baselineOffset` would do it in a label and wreck
        // it in the composer: TextKit 2 drops the clamp when it sees one, and the composer's lines
        // collapse from 28.5pt to 23.75.
        let half = halfLeading
        paragraph.minimumLineHeight = font.pointSize * style.lineHeight - half
        paragraph.maximumLineHeight = font.pointSize * style.lineHeight - half
        paragraph.lineSpacing = half
        // Deliberately NOT setting `lineBreakMode`: on a paragraph style it truncates instead of
        // wrapping, which turned the composer into a single elided line. Clamping is the label's job.
        return [
            .font: font,
            .foregroundColor: UIColor(palette.fg),
            .paragraphStyle: paragraph,
            .kern: font.pointSize * style.trackingEm
        ]
    }

    /// The whole composition: words, and one attachment per token.
    func attributedString(for composition: EntryComposition) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let units = Array(composition.plain.utf16)
        var cursor = 0
        for span in composition.spans {
            if span.span.location > cursor {
                result.append(NSAttributedString(
                    string: String(decoding: units[cursor..<span.span.location], as: UTF16.self),
                    attributes: base()
                ))
            }
            result.append(attachmentString(for: span.token))
            cursor = span.span.endLocation
        }
        if cursor < units.count {
            result.append(NSAttributedString(
                string: String(decoding: units[cursor..<units.count], as: UTF16.self),
                attributes: base()
            ))
        }
        // The dictated tail, greyed. Applied as an attribute over the finished string rather than by
        // splitting the runs, so the paragraph style — and therefore the line rhythm the pills sit
        // inside — is identical either way.
        if let volatileFromPlainOffset {
            let start = min(max(0, composition.displayOffset(forPlainOffset: volatileFromPlainOffset)),
                            result.length)
            if start < result.length {
                result.addAttribute(
                    .foregroundColor,
                    value: UIColor(palette.muted),
                    range: NSRange(location: start, length: result.length - start)
                )
            }
        }
        return result
    }

    /// One token = one attachment character, carrying the rendered pill and the token itself.
    func attachmentString(for token: EntryToken) -> NSAttributedString {
        let font = font
        let attachment = NSTextAttachment()
        if let image = TokenPill.image(
            for: token.kind,
            prose: font.pointSize,
            palette: palette,
            dynamicTypeSize: dynamicTypeSize,
            scale: displayScale,
            colorScheme: colorScheme,
            isSelected: token.id == selectedTokenID
        ) {
            image.accessibilityLabel = Self.accessibilityLabel(for: token)
            attachment.image = image
            // Where the artboard puts it: the pill's ICON sits one point above the prose baseline
            // (`vertical-align:1px` on an inline-flex, whose baseline is its first item's), and the
            // pill's own padding hangs below. Centring the box on the x-height — what this used to do
            // — sat the pill low and made a 1.209em pill look like a 1em one.
            attachment.bounds = CGRect(
                x: 0,
                y: -TokenPillMetrics.descent(for: token.kind, prose: font.pointSize),
                width: image.size.width,
                height: image.size.height
            )
        }
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(
            base().merging([.ateToken: TokenBox(token)]) { _, new in new },
            range: NSRange(location: 0, length: string.length)
        )
        return string
    }

    static func accessibilityLabel(for token: EntryToken) -> String {
        switch token.kind {
        case .score(let rating): "Score \(RatingTrack.accessibilityValue(rating))"
        case .place(let place): place.name
        case .tag(let mark): mark.tag.spokenName
        }
    }

    /// Reads a composition back out of an attributed string: the words as typed, and the tokens as the
    /// attachments they are attached to.
    ///
    /// Walks UTF-16 units and rebuilds the string at the end, so an emoji's surrogate pair — or a
    /// combining mark beside a token — can never be split into invalid text.
    static func composition(from storage: NSAttributedString) -> EntryComposition {
        let string = storage.string as NSString
        var units: [UInt16] = []
        var spans: [EntryTokenSpan] = []
        var index = 0
        while index < storage.length {
            let unit = string.character(at: index)
            if unit == objectReplacement,
               let box = storage.attribute(.ateToken, at: index, effectiveRange: nil) as? TokenBox {
                let location = units.count
                units.append(contentsOf: Array(box.token.plainText.utf16))
                spans.append(EntryTokenSpan(
                    token: box.token,
                    span: TextSpan(location: location, length: box.token.plainText.utf16.count)
                ))
            } else if unit != objectReplacement {
                units.append(unit)
            }
            // An object-replacement character with no token is dropped rather than carried into the
            // words. Undo and redo can leave one behind (`replace(_:withText:)` records plain text,
            // so redoing a promotion restores the character without its attachment), and the words
            // are what gets POSTed — an invisible `U+FFFC` inside somebody's entry is not a glitch
            // we get to ship. The editor also heals them in place; this is the seam that makes it
            // impossible either way.
            index += 1
        }
        return EntryComposition(plain: String(decoding: units, as: UTF16.self), spans: spans)
    }

    static let objectReplacement: unichar = 0xFFFC
}

/// The token, boxed so it can live in an attributed string.
final class TokenBox: NSObject {
    let token: EntryToken
    init(_ token: EntryToken) { self.token = token }
}

extension NSAttributedString.Key {
    /// Marks the one character an inline token occupies.
    static let ateToken = NSAttributedString.Key("ateToken")
}
