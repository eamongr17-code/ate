import AteKit
import SwiftUI

/// **The person's words with their tokens still in them**, read-only: the journal slip, the feed slip,
/// the entry page. The same composition the composer edits, rendered as flowing prose.
///
/// SwiftUI `Text` cannot contain a view, so each token is rasterised once and interpolated as an
/// image run. That keeps real text layout — wrapping, line clamping, Dynamic Type, selection of the
/// words around it — rather than rebuilding line breaking in a custom layout, which is where a design
/// like this usually goes wrong.
struct InlineTokenText: View {
    let composition: EntryComposition
    var style: AteTextStyle = .prose
    var lineLimit: Int?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.atePalette) private var palette

    var body: some View {
        text
            .ateText(style)
            .lineLimit(lineLimit)
            .accessibilityLabel(composition.plain)
    }

    /// Runs of words with pill images between them, concatenated into one `Text`.
    private var text: Text {
        let units = Array(composition.plain.utf16)
        var parts: [Text] = []
        var cursor = 0
        for span in composition.spans {
            if span.span.location > cursor {
                parts.append(Text(verbatim: string(units, cursor..<span.span.location)))
            }
            parts.append(pill(for: span.token))
            cursor = span.span.endLocation
        }
        if cursor < units.count {
            parts.append(Text(verbatim: string(units, cursor..<units.count)))
        }
        return parts.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    private func string(_ units: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    private func pill(for token: EntryToken) -> Text {
        let size = AteFont.size(for: style, dynamicTypeSize: dynamicTypeSize)
        guard let image = TokenPill.image(
            for: token.kind,
            prose: size,
            palette: palette,
            dynamicTypeSize: dynamicTypeSize,
            scale: displayScale
        ) else {
            // Fall back to the words themselves: the plain text is always the truth underneath.
            return Text(verbatim: token.plainText)
        }
        return Text(Image(uiImage: image)).baselineOffset(-size * TokenPill.baselineDrop)
    }
}

/// Rasterises a token into an image so it can live inside a `Text` run or a text view's attachment —
/// **one** drawing of a pill, shared by the read-only prose and the editable composer, so the two can
/// never drift apart.
@MainActor
enum TokenPill {
    /// How far below the baseline a pill sits, as a fraction of the prose size (the prototype's
    /// `vertical-align: 1px` at 17pt).
    static let baselineDrop: CGFloat = 0.14

    static func image(
        for kind: EntryTokenKind,
        prose: CGFloat,
        palette: AtePalette,
        dynamicTypeSize: DynamicTypeSize,
        scale: CGFloat
    ) -> UIImage? {
        let key = Key(kind: kind, prose: prose, scale: scale, dynamicTypeSize: dynamicTypeSize, palette: palette)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: view(for: kind, prose: prose)
            .environment(\.atePalette, palette)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        renderer.scale = scale > 0 ? scale : 3
        renderer.isOpaque = false
        guard let image = renderer.uiImage else { return nil }
        cache[key] = image
        return image
    }

    @ViewBuilder
    private static func view(for kind: EntryTokenKind, prose: CGFloat) -> some View {
        switch kind {
        case .score(let rating): ScoreToken(rating: rating, prose: prose)
        case .place(let place): PlaceToken(name: place.name, prose: prose)
        }
    }

    private struct Key: Hashable {
        let kind: EntryTokenKind
        let prose: CGFloat
        let scale: CGFloat
        let dynamicTypeSize: DynamicTypeSize
        let palette: PaletteKey

        init(
            kind: EntryTokenKind,
            prose: CGFloat,
            scale: CGFloat,
            dynamicTypeSize: DynamicTypeSize,
            palette: AtePalette
        ) {
            self.kind = kind
            self.prose = prose
            self.scale = scale
            self.dynamicTypeSize = dynamicTypeSize
            self.palette = PaletteKey(palette)
        }

        /// `Color` is `Hashable`, so the palette keys the cache directly — a pill drawn on paper and
        /// the same pill drawn on the ink ground are different images and must not share a slot.
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
