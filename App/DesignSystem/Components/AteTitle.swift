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
                .foregroundStyle(colour ?? palette.fg)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else {
            TitleLabel(
                text: text,
                font: AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize),
                lineHeight: style.lineHeight,
                trackingEm: style.trackingEm,
                alignment: alignment,
                colour: colour ?? palette.fg
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

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.isAccessibilityElement = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let box = font.pointSize * lineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = box
        paragraph.maximumLineHeight = box
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .trailing: .right
        default: .center
        }
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(colour),
            .paragraphStyle: paragraph,
            .kern: font.pointSize * trackingEm,
            // CSS **centres** the glyphs in a line box; UIKit sits them on the bottom of a clamped
            // one. So every style the design sets tighter than its font — `.h` at 1.0 — drew four
            // points high, which is a visible gap under a 38pt title. Half the leading, signed: it is
            // negative exactly when the box is tighter than the face, which is when CSS overflows it.
            .baselineOffset: (box - (font.ascender - font.descender)) / 2
        ])
    }

    /// SwiftUI proposes a width; the label answers with the height its words need in it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}
