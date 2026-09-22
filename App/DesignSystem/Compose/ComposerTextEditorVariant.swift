#if DEBUG || BETA
import AteKit
import SwiftUI

/// **The `TextEditor` + `AttributedString` attempt, kept running so the verdict can be checked rather
/// than taken on trust.**
///
/// iOS 26 lets `TextEditor` edit an `AttributedString` with an `AttributedTextSelection`, and a custom
/// attribute can be declared and will survive editing. What it cannot do is *draw* a token:
///
/// 1. **No pill.** SwiftUI's text rendering offers `backgroundColor` — a rectangle behind the run. No
///    corner radius, no padding, no inline image or attachment. A score token can only be coloured
///    text on a coloured rectangle, which is not the design's token.
/// 2. **No "one unit" behaviour.** There is no equivalent of `shouldChangeTextIn`, so a backspace
///    deletes one character of `4.5` and leaves `4.` wearing the token attribute. This variant papers
///    over it by re-scanning after every change, which is visibly a repair rather than a behaviour:
///    the intermediate state is on screen for a frame and the caret lands in odd places.
/// 3. **No hit testing.** `AttributedTextSelection` reports a selection, not a tap, so "tap a token to
///    reopen it" can only be approximated by watching the caret — which also fires when someone is
///    just moving through their own sentence.
/// 4. **No attachment metrics.** A token's vertical alignment against the prose can't be set.
///
/// Everything above is inherent, not a missing convenience: the pill needs a custom draw and the unit
/// behaviour needs an edit hook, and `TextEditor` exposes neither. Hence `InlineTokenEditor`.
struct ComposerTextEditorVariant: View {
    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var derived = EntryComposition()

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            Text("TextEditor + AttributedString")
                .ateText(.control)
            Text("A token can only be coloured text on a rectangle — no pill, no unit delete, no tap.")
                .ateText(.meta)
                .foregroundStyle(AtePalette.automatic.muted)

            TextEditor(text: $text, selection: $selection)
                .ateText(.composerProse)
                .scrollContentBackground(.hidden)
                .background(AtePalette.automatic.field)
                .frame(height: 180)
                .onChange(of: text) { _, _ in restyleScores() }

            Text("Plain text")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.automatic.muted)
            Text(derived.plain.isEmpty ? "—" : derived.plain)
                .ateText(.receiptLine)
            ForEach(derived.spans) { span in
                Text(verbatim: "[\(span.span.location)..<\(span.span.endLocation)] "
                    + (span.token.score.map { ScoreFormat.halfStep($0.value) } ?? span.token.place?.name ?? "?"))
                    .ateText(.receiptLine)
            }
        }
        .padding(AteMetrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The repair pass: find every number that looks like a score and paint it. Runs over the whole
    /// text after every keystroke because there is no edit hook to be incremental with — which is the
    /// second half of the problem, not just an implementation choice.
    private func restyleScores() {
        let plain = String(text.characters)
        var spans: [EntryTokenSpan] = []
        for offset in 0...plain.utf16.count {
            guard let found = ScoreLiteral.candidate(in: plain, caretUTF16: offset) else { continue }
            spans.append(EntryTokenSpan(token: EntryToken(kind: .score(found.rating)), span: found.span))
        }
        // The model's own invariant does the de-duplicating: a span whose characters are not exactly
        // the token's text is refused, so the "4" inside a "4.5" drops out on its own.
        let composition = EntryComposition(plain: plain, spans: spans)
        derived = composition

        var styled = AttributedString(plain)
        styled.foregroundColor = AtePalette.automatic.fg
        for span in composition.spans {
            guard let range = characterRange(of: span.span, in: styled, plain: plain) else { continue }
            styled[range].backgroundColor = AteColor.butter
            styled[range].foregroundColor = AteColor.ink
        }
        if styled != text { text = styled }
    }

    /// UTF-16 offsets into an `AttributedString` range. `AttributedString` counts in characters, so
    /// the offsets have to be converted through the plain string first.
    private func characterRange(
        of span: TextSpan,
        in styled: AttributedString,
        plain: String
    ) -> Range<AttributedString.Index>? {
        guard let start = String.Index(utf16Offset: span.location, in: plain) as String.Index?,
              let end = String.Index(utf16Offset: span.endLocation, in: plain) as String.Index?,
              start <= end, end <= plain.endIndex else { return nil }
        let lower = plain.distance(from: plain.startIndex, to: start)
        let length = plain.distance(from: start, to: end)
        let from = styled.index(styled.startIndex, offsetByCharacters: lower)
        return from..<styled.index(from, offsetByCharacters: length)
    }
}

#Preview("TextEditor variant") {
    ComposerTextEditorVariant().ateGround()
}
#endif
