import SwiftUI
import UIKit

extension View {
    /// Sets a wrapping `Text`'s lines `style.lineHeight × size` apart even when that is **tighter**
    /// than the font's own line height — which `lineSpacing` can never do.
    ///
    /// ``AteExactText`` does the same with a `UILabel`, but `ImageRenderer` cannot draw one, so text
    /// on anything that is exported (the shared receipt) uses this: pure SwiftUI, so a snapshot draws
    /// it exactly as the screen does. A single line is untouched.
    func ateTightLines(_ style: AteTextStyle) -> some View {
        modifier(AteTightLinesModifier(style: style))
    }
}

private struct AteTightLinesModifier: ViewModifier {
    let style: AteTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let font = AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize)
        let naturalPitch = max(font.lineHeight, font.pointSize * style.lineHeight)
        let pitch = font.pointSize * style.lineHeight
        AteTightLinesLayout(naturalPitch: naturalPitch, pitch: pitch) {
            content.textRenderer(AteTightLinesRenderer(naturalPitch: naturalPitch, pitch: pitch))
        }
    }
}

/// Moves each line up so the baselines sit `pitch` apart. It only draws: the `Text` keeps its own
/// size, so it is never offered less room than its lines need.
private struct AteTightLinesRenderer: TextRenderer {
    /// Baseline to baseline as the `Text` lays it out: the font's own, or the style's if looser.
    let naturalPitch: CGFloat
    /// Baseline to baseline as the design sets it.
    let pitch: CGFloat

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        guard let first = lines.first else { return }
        // `minimumScaleFactor` may have set the text down; scale the pitch with it.
        let scale = lines.count > 1
            ? (lines[1].typographicBounds.origin.y - first.typographicBounds.origin.y) / naturalPitch
            : 1
        let baseline = first.typographicBounds.origin.y
        for (index, line) in lines.enumerated() {
            var lineContext = context
            let target = baseline + CGFloat(index) * pitch * scale
            lineContext.translateBy(x: 0, y: target - line.typographicBounds.origin.y)
            lineContext.draw(line)
        }
    }
}

/// Reports the height the tightened lines leave, while the `Text` inside is laid out at its own
/// natural height from the top. (25 Oct: the renderer used to report the short height itself, so
/// the `Text` was offered less room than it needed, shrank under `minimumScaleFactor`, and left a
/// gap under every wrapped dish on the receipt.)
private struct AteTightLinesLayout: Layout {
    let naturalPitch: CGFloat
    let pitch: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let size = text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height - trim(size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let natural = text.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        text.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }

    /// What the tighter pitch takes out between the lines. Rounding the line count down only ever
    /// leaves a hair of extra room under the last line, never clips it.
    private func trim(_ height: CGFloat) -> CGFloat {
        let lines = max(1, (height / naturalPitch + 0.05).rounded(.down))
        return (lines - 1) * max(0, naturalPitch - pitch)
    }
}
