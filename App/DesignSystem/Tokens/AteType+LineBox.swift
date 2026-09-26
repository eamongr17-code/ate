import SwiftUI

// **Line boxes, as CSS draws them.** The design's titles are `line-height:1` and its slip names 1.05 —
// tighter than the faces — and SwiftUI's `Text` neither sizes nor seats a line that way by itself.
// These are the helpers that make a `Text` take the artboard's box and put its glyphs where the
// browser put them. No font is named here; every face still comes out of `AteFont`.

extension View {
    /// A **one-line** title in its CSS line box: `.h` is `line-height:1`, and a `Text` left at the
    /// face's taller natural line pushes everything under it several points down (8 under the
    /// Feed's 40pt title). The box is the style's own; the glyphs stay centred in it, as CSS draws
    /// them. For titles that wrap, use `AteExactText`.
    func ateTextLine(_ style: AteTextStyle) -> some View {
        modifier(AteLineBoxModifier(style: style))
    }

    /// The same style with its line box set **exactly** — `line-height` as CSS means it, tighter than
    /// the font's own where the design asks for that (`.h` at 1.0 and 1.05). For a `Text` that has
    /// to wrap at the artboard's rhythm and still expose a baseline to its row; `AteExactText` does
    /// the former but, being a `UILabel`, cannot do the latter.
    func ateTextExact(_ style: AteTextStyle) -> some View {
        modifier(AteExactLineModifier(style: style))
    }
}

private struct AteLineBoxModifier: ViewModifier {
    let style: AteTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .ateText(style)
            .lineLimit(1)
            // One line, always: at the accessibility sizes a title wider than its row is set down
            // to fit rather than cut off (it never wraps, so it can never break a word).
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.5 : 1)
            .frame(height: style.lineBox(dynamicTypeSize))
    }
}

private struct AteExactLineModifier: ViewModifier {
    let style: AteTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let font = AteFont.uiFont(for: style, dynamicTypeSize: dynamicTypeSize)
        return content
            .font(Font(font))
            .tracking(font.pointSize * style.trackingEm)
            .lineHeight(.exact(points: style.lineBox(dynamicTypeSize)))
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

extension AteFont {
    /// **Where CSS puts the first baseline in a line box**, measured from the box's top: half the
    /// leading above the ascender (`line-height` centres the glyphs, and a box tighter than the face
    /// simply overflows it). What a row built out of several exact boxes aligns on.
    static func cssBaseline(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        let font = uiFont(for: style, dynamicTypeSize: dynamicTypeSize)
        let box = style.lineBox(dynamicTypeSize)
        return (box - (font.ascender - font.descender)) / 2 + font.ascender
    }

    /// **How far below CSS an exact line box draws its first baseline.**
    ///
    /// `ateTextExact` sets a `Text`'s line box outright, and when the box is tighter than the face
    /// SwiftUI does not centre the glyphs the way CSS does: it draws them a whole overflow lower,
    /// where CSS splits the overflow above and below (measured on iOS 26 against `Main.dc.html`, on
    /// the 20/21 names and the 26/26 scores, to a third of a point). A row that lays out on exact
    /// boxes lifts its type by this — a visual offset, because the boxes are already the markup's.
    /// Only ever used for boxes tighter than their face (`.h` at 1.0 and 1.05).
    static func exactBaselineDrop(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        let font = uiFont(for: style, dynamicTypeSize: dynamicTypeSize)
        let natural = font.ascender - font.descender
        return max(0, natural - style.lineBox(dynamicTypeSize))
    }

    /// The style's cap height, in points — what a glyph set beside a numeral centres on.
    static func capHeight(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        uiFont(for: style, dynamicTypeSize: dynamicTypeSize).capHeight
    }
}
