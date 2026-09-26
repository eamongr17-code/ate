import SwiftUI
import UIKit

/// **A display title set to the design's exact line height.**
///
/// `.h` is `line-height:1` — the lines of "Nothing / on the tab." sit exactly their own point size
/// apart. SwiftUI's `Text` can only *add* leading to a font's natural line height, never take it
/// away, so a two-line title in `Text` always comes out several points looser than the artboard. A
/// `UILabel` with an `NSParagraphStyle` can set the height outright, which is what the CSS does.
///
/// Single-line titles have no line height to get wrong and stay on `Text`; this is for the ones that
/// break.
struct AteTitle: View {
    let text: String
    var style: AteTextStyle = .emptyTitle
    var alignment: TextAlignment = .center

    var body: some View {
        AteExactText(text: text, style: style, alignment: alignment)
            .accessibilityElement()
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(text)
    }
}

/// Text whose line box is **exactly** `style.lineHeight × size`, in either direction.
///
/// SwiftUI's `lineSpacing` can only add leading to a font's natural line height, so any style the
/// design sets *tighter* than its font — `.h` at 1.0, a receipt's `.note` at 1.35 — comes out loose
/// in a `Text` and there is no modifier that closes it. `NSParagraphStyle` sets the height outright,
/// which is what the prototype's CSS does.
struct AteExactText: View {
    let text: String
    var style: AteTextStyle
    var alignment: TextAlignment = .center
    /// Defaults to the surface's foreground.
    var colour: Color?
    /// Wraps freely by default; a number clamps it there, ending on an ellipsis.
    var lineLimit: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette
    @Environment(\.ateIsSnapshotting) private var isSnapshotting

    var body: some View {
        if isSnapshotting {
            // `ImageRenderer` cannot draw a `UIViewRepresentable` — it paints an "unsupported view"
            // placeholder over it, which is how a shared receipt lost every dish note. So a snapshot
            // falls back to a plain `Text`: it cannot clamp a line box *tighter* than the font, but
            // a note set a point loose is a receipt, and a yellow warning stripe is not.
            Text(text)
                .ateText(style)
                .multilineTextAlignment(alignment)
                .lineLimit(lineLimit)
                .foregroundStyle(colour ?? palette.fg)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else {
            TitleLabel(
                text: text,
                font: AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize),
                lineHeight: style.lineHeight,
                trackingEm: style.trackingEm,
                alignment: alignment,
                colour: colour ?? palette.fg,
                lineLimit: lineLimit
            )
        }
    }
}

extension EnvironmentValues {
    /// True while the subtree is being drawn into an image rather than onto the screen.
    ///
    /// Set by ``ShareImage`` and read by anything that reaches for UIKit: `ImageRenderer` renders a
    /// `UIViewRepresentable` as a placeholder, so the components that use one need a pure-SwiftUI
    /// way to draw themselves for the artefact that actually leaves the app.
    @Entry var ateIsSnapshotting: Bool = false
}

private extension TextAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}

private struct TitleLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    let lineHeight: CGFloat
    let trackingEm: CGFloat
    let alignment: TextAlignment
    let colour: Color
    var lineLimit: Int?

    func makeUIView(context: Context) -> WordFittingLabel {
        let label = WordFittingLabel()
        label.isAccessibilityElement = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: WordFittingLabel, context: Context) {
        label.numberOfLines = lineLimit ?? 0
        let textAlignment: NSTextAlignment = switch alignment {
        case .leading: .left
        case .trailing: .right
        default: .center
        }
        label.content = WordFittingLabel.Content(
            text: text, font: font, lineHeight: lineHeight, trackingEm: trackingEm,
            alignment: textAlignment,
            colour: UIColor(colour),
            truncates: lineLimit != nil
        )
    }

    /// SwiftUI proposes a width; the label answers with the height its words need in it — having
    /// first made sure its longest word fits that width (``WordFittingLabel``).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: WordFittingLabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        label.fit(width: width)
        defer { if label.bounds.width > 0 { label.fit(width: label.bounds.width) } }
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

/// **A label that never breaks a word.**
///
/// UIKit's word wrapping falls back to breaking a word between letters when the word alone is wider
/// than the line — which, at the accessibility sizes, is every long title: "Septemb / er",
/// "Tagliatell / e". So before the words are laid out the whole label is set down just far enough
/// that its widest word fits the width: lines still break only between
/// words. At the design's own size nothing is wider than its line and nothing changes.
final class WordFittingLabel: UILabel {
    struct Content: Equatable {
        var text: String
        var font: UIFont
        var lineHeight: CGFloat
        var trackingEm: CGFloat
        var alignment: NSTextAlignment
        var colour: UIColor
        var truncates: Bool
    }

    var content: Content? {
        didSet {
            guard content != oldValue else { return }
            apply(scale: fittedWidth.map { scale(for: $0) } ?? 1)
        }
    }

    private var fittedWidth: CGFloat?
    /// What the attributed string was last built from, so a layout pass that changes nothing
    /// rebuilds nothing.
    private var applied: (content: Content, scale: CGFloat)?

    /// The floor, far enough down never to be reached in practice: the largest accessibility sizes
    /// are about three times the design's, so a third is roughly the design's own size again. Only
    /// a word too long for the line even there may still break.
    static let minimumScale: CGFloat = 0.3

    func fit(width: CGFloat) {
        fittedWidth = width
        apply(scale: scale(for: width))
    }

    /// SwiftUI asks for sizes at several widths, in any order — an unconstrained one included — so
    /// whatever the last question left behind, the words are set for the width the label actually
    /// got before they are drawn.
    override func layoutSubviews() {
        if bounds.width > 0 { fit(width: bounds.width) }
        super.layoutSubviews()
    }

    /// How far the font has to come down for the widest word to fit `width`.
    func scale(for width: CGFloat) -> CGFloat {
        guard let content, width > 0, width < UIView.layoutFittingExpandedSize.width else { return 1 }
        let widest = content.text
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                NSAttributedString(string: String(word), attributes: [
                    .font: content.font, .kern: content.font.pointSize * content.trackingEm
                ]).size().width
            }
            .max() ?? 0
        guard widest > width else { return 1 }
        return max(Self.minimumScale, (width / widest * 1000).rounded(.down) / 1000)
    }

    private func apply(scale: CGFloat) {
        guard let content else { return }
        if let applied, applied.content == content, applied.scale == scale { return }
        applied = (content, scale)
        let font = scale < 1 ? content.font.withSize(content.font.pointSize * scale) : content.font
        let box = font.pointSize * content.lineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = box
        paragraph.maximumLineHeight = box
        paragraph.alignment = content.alignment
        // Word wrapping in the paragraph, always: a truncating paragraph style makes TextKit break
        // every line but the last between letters. The label's own mode, set after the text,
        // truncates the last line.
        paragraph.lineBreakMode = .byWordWrapping
        attributedText = NSAttributedString(string: content.text, attributes: [
            .font: font,
            .foregroundColor: content.colour,
            .paragraphStyle: paragraph,
            .kern: font.pointSize * content.trackingEm,
            // CSS **centres** the glyphs in a line box; UIKit sits them on the bottom of a clamped
            // one. So every style the design sets tighter than its font — `.h` at 1.0 — drew four
            // points high, which is a visible gap under a 38pt title. Half the leading, signed: it is
            // negative exactly when the box is tighter than the face, which is when CSS overflows it.
            .baselineOffset: (box - (font.ascender - font.descender)) / 2
        ])
        lineBreakMode = content.truncates ? .byTruncatingTail : .byWordWrapping
    }
}
