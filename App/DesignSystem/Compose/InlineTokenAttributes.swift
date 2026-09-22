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

    var font: UIFont { AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize) }

    /// The attributes every run carries: the voice, the ink, an exact line height, and the design's
    /// tracking.
    func base() -> [NSAttributedString.Key: Any] {
        let font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = font.pointSize * style.lineHeight
        paragraph.maximumLineHeight = font.pointSize * style.lineHeight
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
            colorScheme: colorScheme
        ) {
            image.accessibilityLabel = Self.accessibilityLabel(for: token)
            attachment.image = image
            // Centred on the x-height rather than sat on the baseline: the pill is a word in the
            // sentence, not a footnote hanging off it.
            attachment.bounds = CGRect(
                x: 0,
                y: (font.xHeight - image.size.height) / 2,
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
        case .place(let place): "Place \(place.name)"
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
