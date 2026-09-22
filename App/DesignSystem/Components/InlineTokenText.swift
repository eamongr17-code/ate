import AteKit
import SwiftUI
import UIKit

/// **The person's words with their tokens still in them**, read-only: the journal slip, the feed slip,
/// the entry page. The same composition the composer edits, rendered as flowing prose.
///
/// A `UILabel` rather than SwiftUI's `Text`, for one reason with teeth: the design's pill is about
/// 1.2em tall, and SwiftUI takes an image run's height as its line's ascent — so every line with a
/// score in it came out five to eight points taller than the lines around it and a paragraph's rhythm
/// went ragged. `NSParagraphStyle` gives an exact line height that the attachment sits inside, which
/// is what the prototype's CSS does. The label is also cheap enough for a list: no scroll view, no
/// editing, no selection.
struct InlineTokenText: View {
    let composition: EntryComposition
    var style: AteTextStyle = .prose
    var lineLimit: Int?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        InlineTokenLabel(
            composition: composition,
            attributes: InlineTokenAttributes(
                style: style,
                palette: palette,
                dynamicTypeSize: dynamicTypeSize,
                displayScale: displayScale,
                colorScheme: colorScheme
            ),
            lineLimit: lineLimit
        )
        .accessibilityElement()
        .accessibilityLabel(composition.plain)
    }
}

private struct InlineTokenLabel: UIViewRepresentable {
    let composition: EntryComposition
    let attributes: InlineTokenAttributes
    let lineLimit: Int?

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = lineLimit ?? 0
        // `-webkit-line-clamp` ends a clamped slip with an ellipsis; a label that only clips says
        // nothing about the words it dropped.
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
        label.isAccessibilityElement = false
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.numberOfLines = lineLimit ?? 0
        let string = NSMutableAttributedString(attributedString: attributes.attributedString(for: composition))
        // A paragraph style in the string beats the label's own `lineBreakMode`, so a clamped slip
        // has to carry the truncation itself — `-webkit-line-clamp` ends on an ellipsis, and a
        // label that just stops mid-sentence is lying about how much was written.
        if lineLimit != nil {
            let whole = NSRange(location: 0, length: string.length)
            string.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                guard let paragraph = (value as? NSParagraphStyle)?
                    .mutableCopy() as? NSMutableParagraphStyle else { return }
                paragraph.lineBreakMode = .byTruncatingTail
                string.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
        label.attributedText = string
    }

    /// SwiftUI proposes a width; the label answers with the height its words need in it. Without this
    /// a label in a `VStack` sizes to one line and clips.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

/// Rasterises a token into an image so it can live inside a text view's attachment — **one** drawing
/// of a pill, shared by the read-only prose and the editable composer, so the two can never drift.
@MainActor
enum TokenPill {
    /// - Parameter colorScheme: passed explicitly and **not** inherited. `ImageRenderer` draws
    ///   outside the view hierarchy, so it has no trait collection: a dynamic `Color(light:dark:)`
    ///   resolved in there silently comes back light, and every token pill in dark mode was being
    ///   drawn in the light palette. Nothing about a screenshot in light mode shows it.
    static func image(
        for kind: EntryTokenKind,
        prose: CGFloat,
        palette: AtePalette,
        dynamicTypeSize: DynamicTypeSize,
        scale: CGFloat,
        colorScheme: ColorScheme = .light,
        isSelected: Bool = false
    ) -> UIImage? {
        let key = Key(
            kind: kind, prose: prose, scale: scale, dynamicTypeSize: dynamicTypeSize,
            palette: palette, colorScheme: colorScheme, isSelected: isSelected
        )
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: view(for: kind, prose: prose, isSelected: isSelected)
            .environment(\.atePalette, palette)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = scale > 0 ? scale : 3
        renderer.isOpaque = false
        guard let image = renderer.uiImage else { return nil }
        cache[key] = image
        return image
    }

    @ViewBuilder
    private static func view(for kind: EntryTokenKind, prose: CGFloat, isSelected: Bool) -> some View {
        switch kind {
        case .score(let rating): ScoreToken(rating: rating, prose: prose, isSelected: isSelected)
        case .place(let place): PlaceToken(name: place.name, prose: prose)
        }
    }

    private struct Key: Hashable {
        let kind: EntryTokenKind
        let prose: CGFloat
        let scale: CGFloat
        let dynamicTypeSize: DynamicTypeSize
        let palette: PaletteKey
        let colorScheme: ColorScheme
        let isSelected: Bool

        init(
            kind: EntryTokenKind,
            prose: CGFloat,
            scale: CGFloat,
            dynamicTypeSize: DynamicTypeSize,
            palette: AtePalette,
            colorScheme: ColorScheme,
            isSelected: Bool
        ) {
            self.kind = kind
            self.prose = prose
            self.scale = scale
            self.dynamicTypeSize = dynamicTypeSize
            self.palette = PaletteKey(palette)
            self.colorScheme = colorScheme
            self.isSelected = isSelected
        }

        /// A pill drawn on paper and the same pill drawn on the ink ground are different images and
        /// must not share a cache slot.
        struct PaletteKey: Hashable {
            let fg: Color
            let field: Color
            init(_ palette: AtePalette) {
                self.fg = palette.fg
                self.field = palette.field
            }
        }
    }

    private static var cache: [Key: UIImage] = [:]
}
