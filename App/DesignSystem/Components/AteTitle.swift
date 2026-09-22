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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette

    var body: some View {
        TitleLabel(
            text: text,
            font: AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize),
            lineHeight: style.lineHeight,
            trackingEm: style.trackingEm,
            alignment: alignment
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(text)
    }
}

private struct TitleLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    let lineHeight: CGFloat
    let trackingEm: CGFloat
    let alignment: TextAlignment

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.isAccessibilityElement = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = font.pointSize * lineHeight
        paragraph.maximumLineHeight = font.pointSize * lineHeight
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .trailing: .right
        default: .center
        }
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(context.environment.atePalette.fg),
            .paragraphStyle: paragraph,
            .kern: font.pointSize * trackingEm
        ])
    }

    /// SwiftUI proposes a width; the label answers with the height its words need in it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}
