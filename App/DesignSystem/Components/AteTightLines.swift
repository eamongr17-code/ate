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
        content.textRenderer(AteTightLinesRenderer(
            naturalPitch: max(font.lineHeight, font.pointSize * style.lineHeight),
            pitch: font.pointSize * style.lineHeight
        ))
    }
}

/// Moves each line up so the baselines sit `pitch` apart, and reports the height that leaves.
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

    func sizeThatFits(proposal: ProposedViewSize, text: TextProxy) -> CGSize {
        let size = text.sizeThatFits(proposal)
        // Rounding down only ever leaves a hair of extra room under the last line, never clips it.
        let lines = max(1, (size.height / naturalPitch + 0.05).rounded(.down))
        return CGSize(width: size.width, height: size.height - (lines - 1) * max(0, naturalPitch - pitch))
    }
}
