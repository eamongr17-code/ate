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

    /// ``ateTextExact(_:)`` with its glyphs lifted back to where CSS draws them
    /// (``AteFont/exactBaselineDrop(for:dynamicTypeSize:)``): a wrapping title tighter than its face,
    /// standing on its own rather than baseline-aligned in a row.
    func ateTextExactLifted(_ style: AteTextStyle) -> some View {
        modifier(AteExactLiftedModifier(style: style))
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

private struct AteExactLiftedModifier: ViewModifier {
    let style: AteTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .ateTextExact(style)
            .offset(y: -AteFont.exactBaselineDrop(for: style, dynamicTypeSize: dynamicTypeSize))
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
        let drop = max(0, natural - style.lineBox(dynamicTypeSize))
        let overshoot: CGFloat = switch style.voice {
        case .heading: headingDropOvershoot
        case .display: displayDropOvershoot
        case .prose, .mono: 0
        }
        return max(0, drop - font.pointSize * overshoot)
    }

    /// A tall ascender makes the overflow rule above lift a face too far. These are fractions of the
    /// em cut from the lift, per voice.
    ///
    /// Radio Canada Big's vertical metrics (995 ascender, 305 descender, 690 cap) are within a few
    /// units of DM Sans's (992/310/700), so it takes the 0.15 em that DM Sans was measured to need on
    /// build 185 (a slip's 22pt score sat 3.3pt above its dish name's baseline). Young Serif, which
    /// held this slot before 7 Nov, needed 0.285 for its 1046 ascender.
    private static let headingDropOvershoot: CGFloat = 0.15

    /// Radio Canada is shorter (945/255): its natural line is 1.2 em, a third less overflow over a
    /// 1.0 box than DM Sans's, so its cut shrinks in proportion. Not yet measured on a device.
    private static let displayDropOvershoot: CGFloat = 0.10

    /// The style's cap height, in points — what a glyph set beside a numeral centres on.
    static func capHeight(for style: AteTextStyle, dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        uiFont(for: style, dynamicTypeSize: dynamicTypeSize).capHeight
    }
}
